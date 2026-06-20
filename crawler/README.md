# GlobalRadar AI — Crawler Engine

> 高防封、自愈型采集引擎 + Supabase Realtime + React 前端实时联动

## 文件清单

| 文件 | 说明 |
|------|------|
| `schema.sql` | Supabase 数据库初始化 — radar_clues 表 + Realtime Publication + 解密 RPC |
| `crawler_engine.py` | Python 采集引擎 — scrapling + PlaywrightFetcher + 熔断器 + 脱敏 |
| `RadarStreamComponent.tsx` | React 实时组件 — WebSocket 长连接 + 18s 流式浮现 + 金色动效 |

## 快速开始

### 第一步：初始化数据库
1. 登录 Supabase 后台 → SQL Editor
2. 粘贴 `schema.sql` 全部内容并执行
3. 确认输出 `✅ radar_clues 已成功加入 supabase_realtime 广播通道`

### 第二步：启动采集引擎
```bash
# 安装依赖
pip install "scrapling[fetchers]" supabase

# 安装 Playwright 浏览器
scrapling install

# 配置环境变量（可选 — 代理）
export SUPABASE_URL="https://your-project.supabase.co"
export SUPABASE_SERVICE_KEY="your-service-role-key"
export PROXY_ENABLED="false"

# 启动
python crawler_engine.py
```

### 第三步：前端集成
1. 将 `RadarStreamComponent.tsx` 复制到 React 项目
2. 配置环境变量：
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
3. 在页面中引入组件

## 防封策略

| 策略 | 实现 |
|------|------|
| 自愈解析 | `adaptive=True` 自动适配布局变更 |
| 反检测 | PlaywrightFetcher stealth 模式 |
| 随机延迟 | 每次请求 5-15s Jitter |
| 熔断器 | 连续 3 次 403/429/Cloudflare → 休眠 30 分钟 |
| 代理轮换 | 支持动态代理配置 + 每 5 次轮换 |
| 数据脱敏 | SHA-256 哈希 + 部分掩码，明文不入库 |
| 扣费解密 | SECURITY DEFINER RPC + FOR UPDATE 行锁 |
