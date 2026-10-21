#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  凭据预检：外部弹幕服务的官方凭证为空 ⇒ **响亮地红**，而不是静默降级
# ═══════════════════════════════════════════════════════════════════════
#
# # 为什么有这条
#
# ```text
# 实测（2026-10-21）：仓库 secrets 总数 = 0
#   GET /repos/{o}/{r}/actions/secrets → total_count = 0
# ⇒ DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET 都没配。
# ```
# 而 workflow 里那一步是这么写的：
#
# ```yaml
# env:
#   DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}     # ⇒ 空串
# run: flutter build windows --dart-define=DANDANPLAY_APP_ID="$env:DANDANPLAY_APP_ID"
# ```
#
# `--dart-define` 把**空串**编进二进制 ⇒ `String.fromEnvironment` 得到空串 ⇒
# App 回落到「用户自填凭证」，**不报错、不告警、构建成功、CI 全绿**。
# 于是「这个安装包能不能用官方弹幕」这件事，只有在业主装上之后才会暴露。
#
# ★ 这是本仓明令禁止的那一类：**缺件被当成正常**。
#   ⇒ 判定搬到这里，本地与 CI 跑**同一份**，缺了就 exit 1。
#
# # ★★★ 输出必须是纯 ASCII（本文件的硬约束，改输出前先读完这段）★★★
#
# ```text
# 实测（2026-10-21，本机 Active code page = 936）：
#   旧版输出 754 字节，其中 498 字节 ≥ 0x80（UTF-8 中文 / ✅✗ 符号）
#   在 GBK 控制台上不重定向直接跑，看到的是：
#     鍑�鎹�棰勬��锛氶渶瑕� 2 涓�闈炵┖鍙橀噺锛堣眮鍏嶅紑鍏� = ...
#   ⇒ 名字、开关、处置办法**全都读不出来**，等于没有报错信息。
# ```
# 根因不在脚本「用了中文」，在于 **UTF-8 源文件的字节被 GBK 控制台解释**；
# 而且脚本无法替调用方的控制台决定编码（`chcp` 改的是那个窗口的全局状态，
# 且对 mintty/ConPTY 不生效）⇒ **唯一稳的做法是别输出非 ASCII 字节**：
# 0x00-0x7F 在任何代码页下都是同一个字符，ASCII 输出天然免疫这个问题。
#
# 约定：**注释**随便写中文（注释不会被回显）；**任何 printf / echo 的字符串
# 都必须是纯 ASCII**。判定符号用 [OK] / [FAIL] / [WARN]，不用 ✅✗⚠。
# ⇒ 代价：CI 注解是英文的。这是为了让「本机跑」和「CI 跑」读到同一句话。
#
# # 判据（唯一权威，别处只准引用这里）
#
# ```text
# 对 REQUIRED 里每个变量名 N：
#   v = 环境变量 N 的值（不存在 ≡ 空串）
#   ① 去掉所有空白后为空        ⇒ 缺（空 / 全是空格都算缺）
#   ② v 含未展开的表达式记号     ⇒ 缺（说明 workflow 没把 secret 注进来，
#                                   而是把表达式字面量当值传出来了）
#   任一命中 ⇒ 判红
# ```
#
# # 豁免（唯一合法的放行路径：**仓库变量**，不是改判据、不是列白名单）
#
# ```text
# ALLOW_EMPTY_CREDENTIALS=true   （true / 1 / yes / on，大小写与空白不敏感）
#   ⇒ 打 ::warning:: 并以 0 退出。
# ```
# ★ 为什么放行要靠变量而不是 `if: secrets.X != ''`：
#   `secrets` 上下文**不能**出现在 `if:` 里（GitHub 只允许它出现在
#   `env:` / `with:` / `run:` 这类注入点）。而在 shell 里判「有没有配」本来就
#   只能判**值**：Actions 不提供「列出 secret 名」的能力（那需要 PAT）。
#   ⇒ 判值 + 显式豁免开关，是唯一不需要额外凭据的落地方式。
#
# # 用法
#
# ```bash
# # 本地：把值导进去再跑（不给就是空的 ⇒ 会红，这正是要验的行为）
# DANDANPLAY_APP_ID=xxx DANDANPLAY_APP_SECRET=yyy bash tools/check_required_secrets.sh
#
# # 只想确认门禁本身没坏、暂时接受空值（CI 上就是仓库变量）
# ALLOW_EMPTY_CREDENTIALS=true bash tools/check_required_secrets.sh
#
# # 加第三方凭证：位置参数覆盖默认名单（判定口径完全一样）
# bash tools/check_required_secrets.sh FOO_TOKEN BAR_KEY
# ```
#
# 退出码：0 = 全部就位（或已显式豁免）；1 = 有缺的（**不许当 0 用**）。
#
# # 绝不打印值的任何片段
#
# 只打**变量名**。不打值、不打长度、不打前几位、不打哈希 ——
# 日志是公开的（fork PR 的日志尤其），任何由值派生的量都是在往外漏。
# ═══════════════════════════════════════════════════════════════════════

# ★ 不用 `set -e`：要把**所有**缺的变量一次报全，而不是撞到第一个就退。
set -uo pipefail

# 豁免开关的变量名（自身也可以被覆盖，方便测试）
ALLOW_VAR="${ALLOW_VAR:-ALLOW_EMPTY_CREDENTIALS}"

# 默认必填名单。★ 只写**变量名**，不写值；加新凭证就往这里加一行。
if [ "$#" -gt 0 ]; then
  REQUIRED=("$@")
else
  REQUIRED=(DANDANPLAY_APP_ID DANDANPLAY_APP_SECRET)
fi

allow_ok() {
  # 豁免开关的取值判定：true / 1 / yes / on（大小写与前后空白不敏感）
  local raw norm
  raw="${!ALLOW_VAR:-}"
  norm="$(printf '%s' "$raw" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$norm" in
    true | 1 | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# ★ 先算豁免：它是**唯一**决定「缺失该打 ::error:: 还是 ::warning::」的开关。
#   为什么必须有这个区分：一个**通过**的步骤若挂着 ::error:: 注解，
#   读者会以为「红了但被吞了」—— 那本身就是一种含糊门禁。
if allow_ok; then
  allow=1
else
  allow=0
fi

# ★ 下面每一行输出都是纯 ASCII（原因见文件头「输出必须是纯 ASCII」）。
if [ "$allow" -eq 1 ]; then
  allow_hint="ON (missing credentials only warn)"
else
  allow_hint="OFF (missing credentials fail the build)"
fi
printf 'credential preflight: %d required var(s); exemption %s = %s\n' \
  "${#REQUIRED[@]}" "$ALLOW_VAR" "$allow_hint"

missing=()
for name in "${REQUIRED[@]}"; do
  # ★ 变量名本身先校验：非法名字会让间接展开失败，报出来比静默跳过好
  case "$name" in
    '' | [0-9]* | *[!A-Za-z0-9_]*)
      printf '::error::[FAIL] %s is not a valid env var name -- preflight cannot run\n' "$name"
      exit 1
      ;;
  esac

  value="${!name:-}"
  # ① 去掉所有空白后为空 ⇒ 缺（空串与「只有空格」一视同仁）
  squeezed="$(printf '%s' "$value" | tr -d '[:space:]')"
  if [ -z "$squeezed" ]; then
    if [ "$allow" -eq 1 ]; then
      printf '  [FAIL] %s is empty -- exemption is ON, warning only\n' "$name"
    else
      printf '::error::[FAIL] %s is empty -- the installer would embed an empty credential and the app would silently fall back to "user-supplied credentials"\n' "$name"
    fi
    missing+=("$name")
    continue
  fi

  # ② 含未展开的表达式记号 ⇒ 缺（值不是真实凭据，是写法错误）
  #   ★ 模式用单引号：`$` 在单引号里不展开，这里要的就是那个字面序列。
  case "$value" in
    *'${{'*)
      if [ "$allow" -eq 1 ]; then
        printf '  [FAIL] %s is not a real credential (contains an unevaluated expression) -- exemption is ON, warning only\n' "$name"
      else
        printf '::error::[FAIL] %s is not a real credential (contains an unevaluated expression) -- the secrets injection in the workflow is malformed\n' "$name"
      fi
      missing+=("$name")
      continue
      ;;
  esac

  printf '  [OK] %s is set\n' "$name"
done

if [ "${#missing[@]}" -eq 0 ]; then
  printf '[OK] credential preflight passed (%d var(s) non-empty)\n' "${#REQUIRED[@]}"
  exit 0
fi

missing_list="$(IFS=', '; echo "${missing[*]}")"

if [ "$allow" -eq 1 ]; then
  printf '::warning::[WARN] %d required credential(s) missing (%s) but %s is explicitly set -- continuing in DEGRADED mode\n' \
    "${#missing[@]}" "$missing_list" "$ALLOW_VAR"
  printf '::warning::[WARN] the built installer will NOT contain the official danmaku credentials; users must fill them in themselves\n'
  exit 0
fi

printf '::error::[FAIL] credential preflight failed: %d var(s) missing (%s)\n' \
  "${#missing[@]}" "$missing_list"
printf '::error::[FAIL] fix A: add them in Settings -> Secrets and variables -> Actions -> New repository secret\n'
printf '::error::[FAIL] fix B: if this build truly accepts empty credentials, set repository variable %s to true (warns, never silent)\n' "$ALLOW_VAR"
# ★ exit 1（不是 2、不是 0）：这里「缺件」是**判定结果**，不是「查不到」。
exit 1
