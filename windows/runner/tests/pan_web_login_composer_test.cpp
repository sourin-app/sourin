#define FLUTTER_PLUGIN_IMPL
#include <windows.h>
#include <desktop_webview_window/webview_window_composer.h>
#include <flutter/binary_messenger.h>
#include <flutter/standard_method_codec.h>
#include <cstdio>
#include <cstdlib>
#include <vector>

namespace fixture {
UINT dpi = 96;
bool timer_failure = false;
int create_fail_after = -1;
DWWComposer composer{};
int back = 0, forward = 0, reload = 0, stop = 0;
UINT Dpi(HWND) { return dpi; }
UINT_PTR Timer(HWND window, UINT_PTR id, UINT delay, TIMERPROC callback) {
  return timer_failure ? 0 : SetTimer(window, id, delay, callback);
}
HWND Create(DWORD ex, LPCWSTR name, LPCWSTR text, DWORD style, int x, int y,
            int w, int h, HWND parent, HMENU menu, HINSTANCE instance, LPVOID param) {
  if (create_fail_after == 0) return nullptr;
  if (create_fail_after > 0) --create_fail_after;
  return CreateWindowExW(ex, name, text, style, x, y, w, h, parent, menu, instance, param);
}
}

extern "C" {
void dww_set_composer(const DWWComposer* value) { fixture::composer = value ? *value : DWWComposer{}; }
int32_t dww_browser_go_back(int64_t) { return ++fixture::back; }
int32_t dww_browser_go_forward(int64_t) { return ++fixture::forward; }
int32_t dww_browser_reload(int64_t) { return ++fixture::reload; }
int32_t dww_browser_stop(int64_t) { return ++fixture::stop; }
int32_t dww_browser_close(int64_t) { return 1; }
}

// Exercise the production composer with actual Win32 controls and Flutter codec.
#define GetDpiForWindow fixture::Dpi
#define SetTimer fixture::Timer
#define CreateWindowExW fixture::Create
#include "../pan_web_login_composer.cpp"
#undef GetDpiForWindow
#undef SetTimer
#undef CreateWindowExW

namespace {
int checks = 0;
void Check(bool condition, const char* name) {
  if (!condition) {
    std::printf("FAIL: %s (checks passed=%d)\n", name, checks);
    std::exit(1);
  }
  ++checks;
}
class Messenger : public flutter::BinaryMessenger {
 public:
  mutable std::vector<flutter::BinaryReply> replies;
  mutable std::vector<int64_t> ids;
  flutter::BinaryMessageHandler handler;
  void Send(const std::string& name, const uint8_t* bytes, size_t size,
            flutter::BinaryReply reply) const override {
    Check(name == "sourin/pan-web-login", "channel name");
    auto call = flutter::StandardMethodCodec::GetInstance().DecodeMethodCall(bytes, size);
    Check(call && call->method_name() == "confirm", "confirm method");
    const auto& args = std::get<flutter::EncodableMap>(*call->arguments());
    Check(args.size() == 1, "confirm carries ID only");
    ids.push_back(std::get<int64_t>(args.at(flutter::EncodableValue("browserId"))));
    replies.push_back(std::move(reply));
  }
  void SetMessageHandler(const std::string&, flutter::BinaryMessageHandler value) override {
    handler = std::move(value);
  }
  void State(int64_t id, const char* state) {
    const auto& codec = flutter::StandardMethodCodec::GetInstance();
    auto bytes = codec.EncodeMethodCall(flutter::MethodCall<flutter::EncodableValue>(
        "setState", std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
          {flutter::EncodableValue("browserId"), flutter::EncodableValue(id)},
          {flutter::EncodableValue("state"), flutter::EncodableValue(state)}})));
    bool replied = false;
    handler(bytes->data(), bytes->size(), [&](const uint8_t*, size_t) { replied = true; });
    Check(replied, "state receives response");
  }
  void Error(size_t index) {
    const auto bytes = flutter::StandardMethodCodec::GetInstance().EncodeErrorEnvelope("fixture", "synthetic");
    replies.at(index)(bytes->data(), bytes->size());
  }
};
RECT Bounds(HWND child, HWND parent) {
  RECT rect{};
  GetWindowRect(child, &rect);
  MapWindowPoints(nullptr, parent, reinterpret_cast<POINT*>(&rect), 2);
  return rect;
}
bool Fits(HWND button, HWND parent, int width) {
  wchar_t text[80]{};
  GetWindowTextW(button, text, 80);
  HDC dc = GetDC(button);
  auto old = SelectObject(dc, reinterpret_cast<HFONT>(SendMessage(button, WM_GETFONT, 0, 0)));
  SIZE size{};
  GetTextExtentPoint32W(dc, text, lstrlenW(text), &size);
  SelectObject(dc, old);
  ReleaseDC(button, dc);
  const auto rect = Bounds(button, parent);
  return rect.left >= 0 && rect.right <= width && rect.right - rect.left >= size.cx + MulDiv(16, fixture::dpi, 96);
}
}

int main() {
  SetPriorityClass(GetCurrentProcess(), BELOW_NORMAL_PRIORITY_CLASS);
  SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  Messenger messenger;
  InitializePanWebLoginComposer(&messenger);
  HWND window = CreateWindowExW(0, L"STATIC", L"fixture", WS_OVERLAPPEDWINDOW,
      0, 0, 1000, 700, nullptr, nullptr, GetModuleHandle(nullptr), nullptr);
  HWND view = CreateWindowExW(0, L"STATIC", L"view", WS_CHILD,
      0, 0, 40, 40, window, nullptr, GetModuleHandle(nullptr), nullptr);
  Check(window && view, "hidden native host");
  Check(!IsWindowVisible(window), "host never shown");
  DWWComposeRequest request{42, window, view, "other-browser", 0};
  Check(fixture::composer.compose(nullptr, &request) == DWW_COMPOSE_DEFAULT, "other browsers unchanged");
  Check(entries.empty(), "default browser not registered");
  request.arguments = "sourin-pan-login-v1";
  fixture::create_fail_after = 2;
  Check(fixture::composer.compose(nullptr, &request) == DWW_COMPOSE_DEFAULT, "partial creation rolls back");
  Check(entries.empty() && IsWindow(view), "rollback preserves plugin view");
  fixture::create_fail_after = -1;
  Check(fixture::composer.compose(nullptr, &request) == DWW_COMPOSE_HANDLED, "login browser composed");
  auto& e = entries.at(42);
  for (UINT dpi : {96u, 192u}) {
    fixture::dpi = dpi;
    fixture::composer.layout(nullptr, 42, 320, 400);
    Check(Fits(e.done, e.bar, 320), dpi == 96 ? "320px confirmation fits" : "320px 2x confirmation fits");
    Check(Bounds(view, window).top == MulDiv(48, dpi, 96), "view below toolbar");
  }
  fixture::dpi = 96;
  fixture::composer.layout(nullptr, 42, 1000, 700);
  DWWNavigationState navigation{42, 1, 0, 1, nullptr, nullptr};
  fixture::composer.navigation_changed(nullptr, &navigation);
  Check(IsWindowEnabled(GetDlgItem(e.bar, 1)) && !IsWindowEnabled(GetDlgItem(e.bar, 2)), "navigation availability");
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(3, BN_CLICKED), 0);
  Check(fixture::stop == 1 && fixture::reload == 0, "loading button stops");
  navigation.is_loading = 0;
  fixture::composer.navigation_changed(nullptr, &navigation);
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(3, BN_CLICKED), 0);
  Check(fixture::reload == 1, "loaded button reloads");
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  Check(messenger.ids.size() == 1 && messenger.ids[0] == 42 && !IsWindowEnabled(e.done), "one confirmation while busy");
  messenger.State(99, "waiting");
  Check(!IsWindowEnabled(e.done), "wrong ID cannot unlock");
  messenger.State(42, "error");
  Check(IsWindowEnabled(e.done), "failure retries");
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  messenger.Error(0);
  Check(!IsWindowEnabled(e.done), "late first error cannot unlock second confirm");
  messenger.replies.at(1)(nullptr, 0);
  Check(IsWindowEnabled(e.done), "not implemented restores button");
  fixture::timer_failure = true;
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  Check(IsWindowEnabled(e.done) && messenger.ids.size() == 2, "timer failure cannot deadlock");
  fixture::timer_failure = false;
  SendMessage(e.bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  SendMessage(e.bar, WM_TIMER, 1, 0);
  Check(IsWindowEnabled(e.done), "timer restores button");
  const auto bar = e.bar;
  const auto font = e.font;
  fixture::composer.closing(nullptr, 42);
  Check(entries.empty() && !IsWindow(bar) && IsWindow(view), "closing releases own controls only");
  LOGFONTW lf{};
  Check(!GetObjectW(font, sizeof(lf), &lf), "closing releases font");
  request.browser = 42;
  Check(fixture::composer.compose(nullptr, &request) == DWW_COMPOSE_HANDLED, "reused ID opens new epoch");
  SendMessage(entries.at(42).bar, WM_COMMAND, MAKEWPARAM(4, BN_CLICKED), 0);
  messenger.Error(2);
  Check(!IsWindowEnabled(entries.at(42).done), "closed epoch error cannot affect reused ID");
  DisposePanWebLoginComposer();
  Check(entries.empty() && !messenger.handler && !fixture::composer.compose, "dispose unbinds composer and channel");
  messenger.Error(3);
  Check(IsWindow(view), "late disposal reply preserves plugin view");
  DestroyWindow(window);
  std::printf("PASS: %d checks; hidden native host; no credentials or network\n", checks);
  return 0;
}
