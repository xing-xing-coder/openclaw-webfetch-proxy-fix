# openclaw-webfetch-proxy-fix
Fix OpenClaw web_fetch failing under TUN/Fake-IP proxy by forcing env proxy and adjusting fetch-guard logic

用于修复 **OpenClaw 2026.3.13** 在 **Fake-IP + TUN 代理环境** 下，`web_fetch` 因提前进行本地 DNS / SSRF pinned DNS 解析而命中内网地址、导致请求失败的问题。

本仓库中的脚本来源于：

- 原始仓库：<https://github.com/Bingtao-Wang/openclaw-webfetch-proxy-fix>

我基于原始脚本做了部分修改，主要包括：

- 更通用的 `dist` 路径探测
- 适配当前版本的 `fetch-guard` 顺序修复
- 自动跳过备份文件
- 更适合 `systemd --user` 的重启方式

---

## 适用范围

### OpenClaw 版本

当前脚本按以下版本实测适配：

- **OpenClaw 2026.3.13**

### 安装方式

当前脚本主要面向以下安装方式：

- `npm` / `pnpm` / `yarn` 全局安装后的 `dist` 目录
- 使用 `systemd --user` 启动的 `openclaw-gateway`

如果你的 OpenClaw 是其他安装方式，也可以使用，但需要先确认**实际运行的 `dist` 目录**。

---

## 问题现象

在以下环境下：

- 已开启 Clash Verge Rev / Mihomo / Clash Meta 等 TUN 代理
- 代理模式使用 **Fake-IP**
- OpenClaw 已配置 `HTTP_PROXY` / `HTTPS_PROXY`

`web_fetch` 仍可能报错，常见表现为：

- 返回内网地址
- `private address`
- `loopback`
- `SSRF blocked`
- 域名被提前解析成 Fake-IP 网段地址

根本原因不是代理没设置，而是：

> `web_fetch` 内部的 guarded fetch 流程，会先执行 `resolvePinnedHostnameWithPolicy()`，然后才决定是否走 `EnvHttpProxyAgent()`。

在 Fake-IP 环境下，这会导致域名先被本地解析成假 IP，后续代理也救不回来。

---

## 修复思路

补丁分三部分：

### Patch A

给 `runWebFetch()` 相关调用强制加入：

```js
useEnvProxy: true
```

### Patch B

调整 `fetch-guard` 的关键逻辑顺序。

**修复前：**

```js
const pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {...});
if (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) {
    dispatcher = new EnvHttpProxyAgent();
} else if (params.pinDns !== false) {
    dispatcher = createPinnedDispatcher(pinned, params.dispatcherPolicy);
}
```

**修复后：**

```js
if (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) {
    dispatcher = new EnvHttpProxyAgent();
} else {
    const pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {...});
    if (params.pinDns !== false) {
        dispatcher = createPinnedDispatcher(pinned, params.dispatcherPolicy);
    }
}
```

核心目标：

> 先决定是否走环境代理；只有不走代理时才进行 pinned DNS。

### Patch C

让 `withStrictWebToolsEndpoint()` 也显式带上：

```js
useEnvProxy: true
```

---

## 代理端口说明

不同代理软件默认端口不同，请根据你的环境修改：

### 常见示例

- **Clash Verge Rev / Mihomo** 常见 HTTP 代理端口：`7897`
- **v2rayN** 常见 HTTP 代理端口：`10808`

例如：

```ini
http_proxy=http://127.0.0.1:7897
https_proxy=http://127.0.0.1:7897
```

或：

```ini
http_proxy=http://127.0.0.1:10808
https_proxy=http://127.0.0.1:10808
```

请以你本机代理软件中的 **HTTP/HTTPS 代理端口** 为准，而不是盲目照抄示例。

---

## 如何确认 OpenClaw 实际运行目录

很多人 patch 失败，不是脚本错，而是**打错了 `dist` 目录**。

如果你是 `systemd --user` 启动，先执行：

```bash
systemctl --user cat openclaw-gateway
```

重点看：

```ini
ExecStart=/usr/bin/node /path/to/openclaw/dist/entry.js gateway --port ...
```

其中 `/path/to/openclaw/dist` 就是你要 patch 的真实目录。

### 常见路径示例

可能出现这些安装路径：

```bash
~/.npm-global/lib/node_modules/openclaw/dist
~/.npm/lib/node_modules/openclaw/dist
~/.local/share/npm/node_modules/openclaw/dist
$(npm root -g)/openclaw/dist
~/.openclaw/node_modules/openclaw/dist
```

如果你不确定当前全局 npm 目录，可以先看：

```bash
npm root -g
```

然后再拼接：

```bash
$(npm root -g)/openclaw/dist
```

---

## 代理环境变量配置

如果 OpenClaw 由 `systemd --user` 管理，建议把代理配置写到 service 里。

例如：

```ini
[Service]
Environment=http_proxy=http://127.0.0.1:7897
Environment=https_proxy=http://127.0.0.1:7897
Environment=HTTP_PROXY=http://127.0.0.1:7897
Environment=HTTPS_PROXY=http://127.0.0.1:7897
```

如果你用的是 v2rayN，可能是：

```ini
[Service]
Environment=http_proxy=http://127.0.0.1:10808
Environment=https_proxy=http://127.0.0.1:10808
Environment=HTTP_PROXY=http://127.0.0.1:10808
Environment=HTTPS_PROXY=http://127.0.0.1:10808
```

修改后执行：

```bash
systemctl --user daemon-reload
systemctl --user restart openclaw-gateway
```

验证环境变量是否进入进程：

```bash
tr '\0' '\n' < /proc/$(pidof openclaw)/environ | grep -i proxy
```

---

## 使用方法

### 1. 下载脚本

```bash
chmod +x patch-openclaw-proxy.sh
```

### 2. 直接自动探测路径执行

```bash
./patch-openclaw-proxy.sh
```

### 3. 如果自动探测失败，手动指定路径执行

例如：

```bash
./patch-openclaw-proxy.sh ~/.npm-global/lib/node_modules/openclaw/dist
```

或：

```bash
./patch-openclaw-proxy.sh "$(npm root -g)/openclaw/dist"
```

如果你是从 `systemctl --user cat openclaw-gateway` 中拿到的路径，也可以直接传入。

---

## 补丁脚本

见仓库中的：

- `patch-openclaw-proxy.sh`

---

## 验证补丁是否生效

### 验证 1：环境变量是否在进程里

```bash
tr '\0' '\n' < /proc/$(pidof openclaw)/environ | grep -i proxy
```

预期至少看到：

```bash
http_proxy=http://127.0.0.1:7897
https_proxy=http://127.0.0.1:7897
HTTP_PROXY=http://127.0.0.1:7897
HTTPS_PROXY=http://127.0.0.1:7897
```

端口按你的实际代理配置为准。

### 验证 2：确认 fetch-guard 顺序已经变更

```bash
grep -R -n -C 8 --exclude='*.bak_proxy_patch*' "TRUSTED_ENV_PROXY" /path/to/openclaw/dist/plugin-sdk
```

在 `fetch-guard-*.js` 中，应看到类似：

```js
if (mode === GUARDED_FETCH_MODE.TRUSTED_ENV_PROXY && hasProxyEnvConfigured()) dispatcher = new EnvHttpProxyAgent();
else {
    const pinned = await resolvePinnedHostnameWithPolicy(parsedUrl.hostname, {
        lookupFn: params.lookupFn,
        policy: params.policy
    });
    if (params.pinDns !== false) dispatcher = createPinnedDispatcher(pinned, params.dispatcherPolicy);
}
```

这表示顺序已经修正。

### 验证 3：实际测试 `web_fetch`

建议测试以下目标：

```text
https://github.com
https://example.com
```

如果之前会报 `private address` / `SSRF blocked` / 内网地址，现在应恢复正常。

---

## 注意事项

### 1. 这是基于 dist 的补丁，不是源码补丁

也就是说它直接修改 npm 安装后的编译产物：

- 升级 OpenClaw 后可能失效
- 重新安装后可能被覆盖
- 每次升级后建议重新执行

### 2. 不同版本的 dist 结构可能不同

本脚本按 **OpenClaw 2026.3.13** 的编译输出适配。未来版本如果：

- chunk 名变化
- 代码结构变化
- `fetch-guard` 逻辑调整

可能需要重新适配正则。

### 3. 必须确认实际运行目录

一定先确认 `ExecStart` 里真正使用的是哪份 `dist`，不要 patch 错目录。

### 4. 必须用 service 重启

如果你是 `systemd --user` 管理，就统一用：

```bash
systemctl --user restart openclaw-gateway
```

不要混用其他启动方式。

### 5. 会生成备份文件

每个被修改的文件首次会生成：

```bash
*.bak_proxy_patch
```

便于手动回滚。

### 6. 后续官方可能已修复

OpenClaw 项目已经有人在反馈并提交相关修复：

- PR #40354: <https://github.com/openclaw/openclaw/pull/40354>

目前该 PR 仍是 **open** 状态，建议后续自行关注是否已合并到主分支。

如果后续官方已经修复并发布正式版本，**就不再需要本脚本**。

---

## 回滚方法

如果需要回滚，可以把备份恢复回来。

示例：

```bash
cp file.js.bak_proxy_patch file.js
```

如果要批量恢复，可自行写脚本，把所有 `*.bak_proxy_patch` 覆盖回原文件。

---

## 致谢

- 原始脚本来源：<https://github.com/Bingtao-Wang/openclaw-webfetch-proxy-fix>
- 我在原始脚本基础上进行了部分修改与适配
- 同时感谢 OpenClaw 项目中已经对该问题进行反馈和修复尝试的贡献者

---

## 经验总结

这次排查中最关键的几点：

1. OpenClaw 实际由 `systemd --user` 管理，不是普通 shell 启动
2. 仅写 `.bashrc` 不会影响 user service
3. service 已经带上代理环境变量，但问题仍存在
4. `useEnvProxy: true` 并不够，关键是必须把 `EnvHttpProxyAgent()` 放到 `resolvePinnedHostnameWithPolicy()` 之前
5. 真正的根因是 Fake-IP 环境下的“先 DNS，后代理”顺序错误
