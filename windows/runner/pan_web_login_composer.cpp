#include "pan_web_login_composer.h"
#include <desktop_webview_window/webview_window_composer.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <algorithm>
#include <map>
#include <memory>
#include <string>

namespace {
using flutter::EncodableValue;
using flutter::EncodableMap;
struct Entry { HWND window; HWND view; HWND bar; HWND done; HWND status; uint64_t epoch; bool loading; uint64_t confirm = 0; HFONT font = nullptr; int font_dpi = 0; };
std::map<int64_t, Entry> entries;
uint64_t next_epoch = 0;
std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel;
constexpr wchar_t kClass[] = L"SourinPanLoginToolbar";

void Recover(int64_t browser, uint64_t epoch, uint64_t confirm) {
  const auto found = entries.find(browser);
  if (found == entries.end() || found->second.epoch != epoch || found->second.confirm != confirm) return;
  KillTimer(found->second.bar, 1);
  EnableWindow(found->second.done, TRUE);
  SetWindowTextW(found->second.status, L"\u672a\u5b8c\u6210\uff0c\u8bf7\u91cd\u8bd5");
}

class ConfirmResult : public flutter::MethodResult<EncodableValue> {
 public:
  ConfirmResult(int64_t browser, uint64_t epoch, uint64_t confirm) : browser_(browser), epoch_(epoch), confirm_(confirm) {}
 protected:
  void SuccessInternal(const EncodableValue*) override {}
  void ErrorInternal(const std::string&, const std::string&, const EncodableValue*) override { Recover(browser_, epoch_, confirm_); }
  void NotImplementedInternal() override { Recover(browser_, epoch_, confirm_); }
 private:
  int64_t browser_; uint64_t epoch_; uint64_t confirm_;
};

LRESULT CALLBACK ToolbarProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_TIMER && wparam == 1) {
    const auto browser = static_cast<int64_t>(GetWindowLongPtr(window, GWLP_USERDATA));
    const auto found = entries.find(browser);
    if (found != entries.end() && found->second.bar == window) Recover(browser, found->second.epoch, found->second.confirm);
    return 0;
  }
  if (message == WM_COMMAND && HIWORD(wparam) == BN_CLICKED) {
    const auto browser = static_cast<int64_t>(GetWindowLongPtr(window, GWLP_USERDATA));
    const auto found = entries.find(browser);
    if (found == entries.end()) return 0;
    switch (LOWORD(wparam)) {
      case 1: dww_browser_go_back(browser); break;
      case 2: dww_browser_go_forward(browser); break;
      case 3:
        if (found->second.loading) dww_browser_stop(browser);
        else dww_browser_reload(browser);
        break;
      case 4:
        if (channel && IsWindowEnabled(found->second.done)) {
          EnableWindow(found->second.done, FALSE);
          const auto confirm = ++found->second.confirm;
          if (!SetTimer(window, 1, 45000, nullptr)) {
            Recover(browser, found->second.epoch, confirm);
            break;
          }
          channel->InvokeMethod("confirm", std::make_unique<EncodableValue>(
              EncodableMap{{EncodableValue("browserId"), EncodableValue(browser)}}),
              std::make_unique<ConfirmResult>(browser, found->second.epoch, confirm));
        }
        break;
    }
    return 0;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

void Layout(void*, int64_t browser, int32_t width, int32_t height) {
  const auto found = entries.find(browser);
  if (found == entries.end()) return;
  Entry& e = found->second;
  const int dpi = (std::max)(96, static_cast<int>(GetDpiForWindow(e.window)));
  if (e.font_dpi != dpi) {
    HFONT font = CreateFontW(-MulDiv(13, dpi, 96), 0, 0, 0, FW_NORMAL,
        FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
        CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, DEFAULT_PITCH, L"Segoe UI");
    if (font) {
      for (int i = 1; i <= 4; ++i) SendMessage(GetDlgItem(e.bar, i), WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
      SendMessage(e.status, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
      if (e.font) DeleteObject(e.font);
      e.font = font;
      e.font_dpi = dpi;
    }
  }
  const auto px = [dpi](int value) { return MulDiv(value, dpi, 96); };
  const int bar_height = (std::min)(height, px(48));
  MoveWindow(e.bar, 0, 0, width, bar_height, TRUE);
  const bool compact = width < px(244);
  for (int i = 1; i <= 3; ++i) {
    MoveWindow(GetDlgItem(e.bar, i), px(8 + (i - 1) * 36), px(8), px(32), px(32), TRUE);
    ShowWindow(GetDlgItem(e.bar, i), compact ? SW_HIDE : SW_SHOW);
  }
  const int done_width = (std::min)(px(112), (std::max)(0, width - px(compact ? 16 : 124)));
  MoveWindow(e.done, (std::max)(0, width - done_width - px(8)), px(8), done_width, px(32), TRUE);
  const int status_width = (std::max)(0, width - px(252));
  MoveWindow(e.status, px(120), px(14), status_width, px(24), TRUE);
  ShowWindow(e.status, !compact && status_width > px(80) ? SW_SHOW : SW_HIDE);
  MoveWindow(e.view, 0, bar_height, width, (std::max)(0, height - bar_height), TRUE);
}

DWWComposeResult Compose(void*, const DWWComposeRequest* request) {
  if (!channel || !request->arguments || std::string(request->arguments) != "sourin-pan-login-v1" ||
      entries.find(request->browser) != entries.end())
    return DWW_COMPOSE_DEFAULT;
  static const bool registered = [] {
    WNDCLASSW cls{};
    cls.lpfnWndProc = ToolbarProc; cls.hInstance = GetModuleHandle(nullptr);
    cls.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1); cls.lpszClassName = kClass;
    return RegisterClassW(&cls) != 0;
  }();
  if (!registered) return DWW_COMPOSE_DEFAULT;
  const auto window = static_cast<HWND>(request->window);
  const auto view = static_cast<HWND>(request->webview_view);
  HWND bar = CreateWindowExW(0, kClass, L"", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
      window, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!bar) return DWW_COMPOSE_DEFAULT;
  SetWindowLongPtr(bar, GWLP_USERDATA, static_cast<LONG_PTR>(request->browser));
  const wchar_t* labels[] = {L"\u2190", L"\u2192", L"\u21bb", L"\u5b8c\u6210\u767b\u5f55"};
  HWND done = nullptr;
  for (int i = 0; i < 4; ++i) {
    HWND button = CreateWindowExW(0, L"BUTTON", labels[i], WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON,
        0, 0, 0, 0, bar, reinterpret_cast<HMENU>(static_cast<INT_PTR>(i + 1)), GetModuleHandle(nullptr), nullptr);
    if (!button) { DestroyWindow(bar); return DWW_COMPOSE_DEFAULT; }
    SendMessage(button, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
    if (i == 3) done = button;
  }
  HWND status = CreateWindowExW(0, L"STATIC", L"\u767b\u5f55\u540e\u70b9\u51fb\u5b8c\u6210", WS_CHILD | WS_VISIBLE,
      0, 0, 0, 0, bar, nullptr, GetModuleHandle(nullptr), nullptr);
  if (!status) { DestroyWindow(bar); return DWW_COMPOSE_DEFAULT; }
  SendMessage(status, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), TRUE);
  entries.emplace(request->browser, Entry{window, view, bar, done, status, ++next_epoch, false});
  RECT rect{}; GetClientRect(window, &rect);
  Layout(nullptr, request->browser, rect.right, rect.bottom);
  return DWW_COMPOSE_HANDLED;
}

void Closing(void*, int64_t browser) {
  const auto found = entries.find(browser);
  if (found == entries.end()) return;
  KillTimer(found->second.bar, 1);
  if (IsWindow(found->second.bar)) DestroyWindow(found->second.bar);
  if (found->second.font) DeleteObject(found->second.font);
  entries.erase(found);
}

void NavigationChanged(void*, const DWWNavigationState* state) {
  const auto found = entries.find(state->browser);
  if (found == entries.end()) return;
  found->second.loading = state->is_loading != 0;
  EnableWindow(GetDlgItem(found->second.bar, 1), state->can_go_back != 0);
  EnableWindow(GetDlgItem(found->second.bar, 2), state->can_go_forward != 0);
  SetWindowTextW(GetDlgItem(found->second.bar, 3), state->is_loading ? L"\u00d7" : L"\u21bb");
}
}

void InitializePanWebLoginComposer(flutter::BinaryMessenger* messenger) {
  channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "sourin/pan-web-login", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    const auto* args = std::get_if<EncodableMap>(call.arguments());
    if (call.method_name() != "setState" || !args) { result->NotImplemented(); return; }
    const auto id = args->find(EncodableValue("browserId"));
    const auto state = args->find(EncodableValue("state"));
    if (id == args->end() || state == args->end()) { result->Error("invalid_state", "Invalid login state"); return; }
    int64_t browser = -1;
    if (const auto* wide_id = std::get_if<int64_t>(&id->second)) browser = *wide_id;
    else if (const auto* narrow_id = std::get_if<int32_t>(&id->second)) browser = *narrow_id;
    const auto* text = std::get_if<std::string>(&state->second);
    if (!text || (*text != "waiting" && *text != "busy" && *text != "error")) {
      result->Error("invalid_state", "Invalid login state"); return;
    }
    const auto found = entries.find(browser);
    if (found != entries.end()) {
      if (*text != "busy") KillTimer(found->second.bar, 1);
      EnableWindow(found->second.done, *text != "busy");
      SetWindowTextW(found->second.status, *text == "busy" ? L"\u6b63\u5728\u68c0\u67e5" :
          *text == "error" ? L"\u672a\u5b8c\u6210\uff0c\u8bf7\u91cd\u8bd5" : L"\u767b\u5f55\u540e\u70b9\u51fb\u5b8c\u6210");
      if (*text == "busy" && !SetTimer(found->second.bar, 1, 45000, nullptr)) {
        Recover(browser, found->second.epoch, found->second.confirm);
      }
    }
    result->Success();
  });
  DWWComposer composer{}; composer.compose = Compose; composer.layout = Layout; composer.closing = Closing;
  composer.navigation_changed = NavigationChanged;
  dww_set_composer(&composer);
}

void DisposePanWebLoginComposer() {
  dww_set_composer(nullptr);
  if (channel) channel->SetMethodCallHandler(nullptr);
  channel.reset();
  for (const auto& pair : entries) {
    const Entry& e = pair.second;
    if (IsWindow(e.bar)) DestroyWindow(e.bar);
    if (e.font) DeleteObject(e.font);
    if (IsWindow(e.window) && IsWindow(e.view)) {
      RECT rect{};
      GetClientRect(e.window, &rect);
      MoveWindow(e.view, 0, 0, rect.right, rect.bottom, TRUE);
    }
  }
  entries.clear();
}
