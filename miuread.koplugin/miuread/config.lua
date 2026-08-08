local C = {
    NAME = "觅阅 · 微信读书助手",
    VERSION = "4.3.0-beta.1",
    SCHEMA = 101,
    PLUGIN_DIR = "miuread.koplugin",
    DATA_DIR = "miuread",

    -- 更新清单固定保存在对应发布分支的仓库根目录；清单中的下载地址
    -- 指向 GitHub Release 全量包。安装另一通道的全量包可切换更新通道。
    UPDATE_CHANNEL = "beta",
    UPDATE_CHANNEL_LABEL = "内测通道",
    UPDATE_MANIFEST = "https://raw.githubusercontent.com/miumiupy98-art/device-feed-r7k2/main/update-beta.json",
    UPDATE_MANIFESTS = {
        "https://raw.githubusercontent.com/miumiupy98-art/device-feed-r7k2/main/update-beta.json",
    },

    -- 仅作为 GitHub 官方资源访问失败时的回退入口。
    -- 下载后仍会执行大小与 SHA-256 校验，镜像不能改变安装内容。
    GITHUB_MIRRORS = {
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
    },

    AUTO_UPDATE_INTERVAL = 24 * 60 * 60,
    AUTO_UPDATE_RETRY_INTERVAL = 6 * 60 * 60,

    READ_INTERVAL = 30,
    IDLE_TIMEOUT = 600,
    REMOTE_THRESHOLD = 2,

    -- Coalesce page-turn control snapshots. Reading position stays in memory
    -- and is written at most once per window; suspend/close still flushes now.
    CONTROL_WRITE_DELAY = 30,

    LOW_MEMORY_SETTING = "DGLOBAL_CACHE_FREE_PROPORTION",
    LOW_MEMORY_RATIO = 0.15,

    -- Runtime performance protection is based on measured UI latency, not on
    -- device model or age. The lightweight flag is shared with the download
    -- subprocess so an already-running job can adapt immediately.
    LIGHTWEIGHT_MODE_FLAG = "/tmp/miuread-lightweight-mode.flag",
    PERFORMANCE_SLOW_MS = 1200,
    PERFORMANCE_EXTREME_MS = 2500,
    PERFORMANCE_WINDOW_SECONDS = 10 * 60,
    PERFORMANCE_REPEAT_COUNT = 2,
    PERFORMANCE_PROMPT_COOLDOWN = 7 * 24 * 60 * 60,

    -- Online features are verified by their real request. Renewal is recovery,
    -- never a prerequisite. Diagnostics never include account secrets.
    AUTH_NOTICE_FAILURE_THRESHOLD = 2,
    DOWNLOAD_AUTO_RESTARTS = 2,
    DOWNLOAD_DIAGNOSTIC_KEEP = 3,
    READ_REPORT_AUTH_RETRY_DELAYS = {120, 300, 900, 1800},
    READ_REPORT_CONTEXT_RETRY_DELAYS = {60, 120, 300, 900},
}
return C
