//! Synchronize callback dispatch with terminal isolate teardown.
use std::collections::HashSet;
use std::sync::{OnceLock, RwLock};

#[derive(Default)]
pub(crate) struct CallbackGate {
    detached: RwLock<HashSet<usize>>,
}

impl CallbackGate {
    pub(crate) fn invoke(&self, address: usize, send: impl FnOnce()) -> bool {
        let detached = self.detached.read().unwrap_or_else(|e| e.into_inner());
        if address == 0 || detached.contains(&address) {
            return false;
        }
        // Listener posting does not wait for Dart execution. Hold the guard
        // through that native call so detach cannot race the function pointer.
        send();
        true
    }

    pub(crate) fn detach(&self, addresses: &[usize]) {
        let mut detached = self.detached.write().unwrap_or_else(|e| e.into_inner());
        detached.extend(addresses.iter().copied().filter(|address| *address != 0));
    }
}

pub(crate) fn gate() -> &'static CallbackGate {
    static GATE: OnceLock<CallbackGate> = OnceLock::new();
    GATE.get_or_init(CallbackGate::default)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc};
    use std::time::Duration;

    #[test]
    fn detached_results_are_dropped_before_send_allocates() {
        let gate = CallbackGate::default();
        let mut sent = 0;
        assert!(gate.invoke(11, || sent += 1));
        gate.detach(&[11, 12]);
        assert!(!gate.invoke(11, || sent += 1));
        assert!(!gate.invoke(12, || sent += 1));
        assert_eq!(sent, 1);
        assert!(gate.invoke(13, || sent += 1));
        assert_eq!(sent, 2);
    }

    #[test]
    fn detachment_is_idempotent_and_null_never_calls() {
        let gate = CallbackGate::default();
        gate.detach(&[0, 11, 11]);
        gate.detach(&[11]);
        assert!(!gate.invoke(0, || panic!("null callback")));
        assert!(!gate.invoke(11, || panic!("detached callback")));
    }

    #[test]
    fn detachment_waits_for_inflight_posting_and_blocks_later_posts() {
        let gate = Arc::new(CallbackGate::default());
        let (entered_tx, entered_rx) = mpsc::channel();
        let (release_tx, release_rx) = mpsc::channel();
        let posting_gate = Arc::clone(&gate);
        let posting = std::thread::spawn(move || posting_gate.invoke(11, || {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        }));
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        let (started_tx, started_rx) = mpsc::channel();
        let (detached_tx, detached_rx) = mpsc::channel();
        let detaching_gate = Arc::clone(&gate);
        let detaching = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            detaching_gate.detach(&[11]);
            detached_tx.send(()).unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(detached_rx.recv_timeout(Duration::from_millis(30)).is_err());
        release_tx.send(()).unwrap();
        assert!(posting.join().unwrap());
        detached_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        detaching.join().unwrap();
        assert!(!gate.invoke(11, || panic!("late callback")));
    }
}
