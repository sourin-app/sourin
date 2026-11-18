#pragma once

// Load the plugin's Windows/COM declarations before the WinAPI aliases. COM
// interfaces also declare SetFocus; those member names must remain untouched.
#include <windows.h>
#include <flutter/plugin_registrar_windows.h>
#include <shobjidl_core.h>

#include "task_window_safety.h"
