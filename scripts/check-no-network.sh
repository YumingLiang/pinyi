#!/usr/bin/env bash
# 零网络 / 零第三方依赖守护（技术方案 §9.2「工程守护」）。CI 的 Linux job 调用；本地也可直接运行。
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0

# 1) 源码中禁止的联网 API / 框架 / 常见 SDK（白名单为空）。
pattern='URLSession|URLRequest|NSURLConnection|NWConnection|NWListener|NWPathMonitor|NWBrowser|import[[:space:]]+Network\b|import[[:space:]]+CFNetwork|import[[:space:]]+WebKit|WKWebView|SFSafariViewController|CFStream|getaddrinfo|Firebase|Crashlytics|Sentry|Bugly|Umeng|Alamofire|Moya|AFNetworking'
if matches=$(grep -rEn --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' "$pattern" App AppTests Packages 2>/dev/null | grep -v '/.build/'); then
  echo "::error::Forbidden networking API / SDK found:"
  echo "$matches"
  fail=1
fi

# 2) SwiftPM 不允许任何远程依赖。
if matches=$(grep -rEn --include='Package.swift' '\.package\([[:space:]]*url:' Packages 2>/dev/null | grep -v '/.build/'); then
  echo "::error::Remote SwiftPM dependency found:"
  echo "$matches"
  fail=1
fi

# 3) XcodeGen 的 packages 只允许本地 path。
if grep -En '^[[:space:]]+(url|github):' project.yml; then
  echo "::error::Remote package in project.yml"
  fail=1
fi

if [ "$fail" -ne 0 ]; then exit 1; fi
echo "OK: no networking APIs, no third-party dependencies."
