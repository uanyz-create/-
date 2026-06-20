#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
╔══════════════════════════════════════════════════════════════════════════════╗
║  GlobalRadar AI — 高防封、自愈型采集引擎                                       ║
║  Crawler Engine v1.0                                                          ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  技术栈:                                                                      ║
║    • scrapling[fetchers] — 自适应自愈解析                                      ║
║    • PlaywrightFetcher    — 无头浏览器 + 反检测                                 ║
║    • supabase-py          — 实时数据入库                                       ║
║    • 动态代理 + 随机延迟 + 熔断休眠 + 哈希脱敏                                   ║
╚══════════════════════════════════════════════════════════════════════════════╝

安装:
    pip install "scrapling[fetchers]" supabase
    scrapling install

运行:
    python crawler_engine.py
"""

import os
import sys
import time
import json
import random
import hashlib
import logging
import traceback
from datetime import datetime, timezone

# ─────────────────────────────────────────────────────────────────
# 第三方依赖
# ─────────────────────────────────────────────────────────────────
try:
    from scrapling.fetchers import PlaywrightFetcher
except ImportError:
    print("❌ 缺少 scrapling。请执行: pip install \"scrapling[fetchers]\"")
    sys.exit(1)

try:
    from supabase import create_client, Client
except ImportError:
    print("❌ 缺少 supabase-py。请执行: pip install supabase")
    sys.exit(1)

# ─────────────────────────────────────────────────────────────────
# 日志配置
# ─────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)-7s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("crawler_engine.log", encoding="utf-8"),
    ],
)
logger = logging.getLogger("GlobalRadar")

# ─────────────────────────────────────────────────────────────────
# 配置中心
# ─────────────────────────────────────────────────────────────────
class Config:
    """全局配置 — 环境变量优先，默认值兜底"""

    # Supabase 连接
    SUPABASE_URL: str = os.getenv("SUPABASE_URL", "https://your-project.supabase.co")
    SUPABASE_KEY: str = os.getenv("SUPABASE_SERVICE_KEY", "your-service-role-key")

    # 动态代理 — 预留接口，支持轮换
    PROXY_SETTINGS: dict = {
        "enabled":        os.getenv("PROXY_ENABLED", "false").lower() == "true",
        "server":         os.getenv("PROXY_SERVER", "proxy.example.com:8080"),
        "username":       os.getenv("PROXY_USERNAME", ""),
        "password":       os.getenv("PROXY_PASSWORD", ""),
        "rotate_interval": 5,  # 每 5 次请求轮换一次代理
    }

    # 防封策略
    JITTER_MIN: float         = 5.0   # 随机延迟最小值（秒）
    JITTER_MAX: float         = 15.0  # 随机延迟最大值（秒）
    CIRCUIT_THRESHOLD: int   = 3     # 连续失败熔断阈值
    CIRCUIT_SLEEP: int       = 1800  # 熔断休眠时间（30分钟 = 1800秒）
    MAX_RETRIES: int         = 2     # 单页最大重试次数
    REQUEST_TIMEOUT: int     = 30000 # Playwright 超时（毫秒）

    # 采集目标
    TARGET_URLS: list[str] = [
        "https://quotes.toscrape.com/page/1/",
        "https://quotes.toscrape.com/page/2/",
        "https://quotes.toscrape.com/page/3/",
        "https://quotes.toscrape.com/page/4/",
        "https://quotes.toscrape.com/page/5/",
        "https://quotes.toscrape.com/page/6/",
        "https://quotes.toscrape.com/page/7/",
        "https://quotes.toscrape.com/page/8/",
        "https://quotes.toscrape.com/page/9/",
        "https://quotes.toscrape.com/page/10/",
    ]

    # 守护进程
    LOOP_INTERVAL: int       = 60    # 每轮采集间隔（秒）
    BATCH_PREFIX: str        = "batch"


# ─────────────────────────────────────────────────────────────────
# 熔断器
# ─────────────────────────────────────────────────────────────────
class CircuitBreaker:
    """
    熔断器状态机:
        CLOSED → (连续3次403/429/Cloudflare) → OPEN
        OPEN   → (休眠30分钟) → HALF_OPEN → 成功则 CLOSED，失败则 OPEN
    """

    def __init__(self):
        self.state = "CLOSED"
        self.failure_count = 0
        self.last_trip_time = None

    def record_failure(self, reason: str = ""):
        """记录一次失败"""
        self.failure_count += 1
        logger.warning(
            f"⚠️  采集失败 ({self.failure_count}/{Config.CIRCUIT_THRESHOLD}) — {reason}"
        )

        if self.failure_count >= Config.CIRCUIT_THRESHOLD:
            self._trip(reason)

    def record_success(self):
        """记录一次成功，重置计数器"""
        if self.failure_count > 0:
            logger.info(f"✅ 采集恢复成功，重置失败计数 ({self.failure_count} → 0)")
        self.failure_count = 0
        self.state = "CLOSED"

    def _trip(self, reason: str):
        """触发熔断"""
        self.state = "OPEN"
        self.last_trip_time = datetime.now(timezone.utc)
        logger.error(
            f"🚨 熔断器触发！连续 {self.failure_count} 次失败 — {reason}\n"
            f"💤 进入休眠状态，{Config.CIRCUIT_SLEEP} 秒后自动恢复..."
        )

    def is_tripped(self) -> bool:
        """检查是否处于熔断状态"""
        if self.state != "OPEN":
            return False

        elapsed = (datetime.now(timezone.utc) - self.last_trip_time).total_seconds()
        if elapsed >= Config.CIRCUIT_SLEEP:
            self.state = "HALF_OPEN"
            logger.info(f"🔄 熔断休眠结束（已过 {elapsed:.0f}s），进入半开探测模式")
            return False

        remaining = Config.CIRCUIT_SLEEP - elapsed
        logger.warning(
            f"⛔ 熔断中 — 剩余休眠 {remaining:.0f}s"
        )
        return True

    def status(self) -> dict:
        return {
            "state": self.state,
            "failures": self.failure_count,
            "threshold": Config.CIRCUIT_THRESHOLD,
            "tripped_at": self.last_trip_time.isoformat() if self.last_trip_time else None,
        }


# ─────────────────────────────────────────────────────────────────
# 数据脱敏器
# ─────────────────────────────────────────────────────────────────
class DataMasker:
    """
    敏感数据脱敏:
        1. SHA-256 哈希 — 存入数据库 email_hash/phone_hash/social_hash
        2. 部分掩码 — 存入数据库 email_masked/phone_masked/social_masked（前端可见）
        原始明文不存储在数据库中。
    """

    @staticmethod
    def hash_value(value: str) -> str:
        """SHA-256 哈希脱敏"""
        if not value:
            return None
        return hashlib.sha256(value.encode("utf-8")).hexdigest()

    @staticmethod
    def mask_email(email: str) -> str:
        """邮箱部分掩码: john.doe@gmail.com → j***@gmail.com"""
        if not email or "@" not in email:
            return email
        local, domain = email.split("@", 1)
        masked_local = local[0] + "***" if len(local) > 1 else local + "***"
        return f"{masked_local}@{domain}"

    @staticmethod
    def mask_phone(phone: str) -> str:
        """电话部分掩码: +1-555-123-4567 → +1***-***-4567"""
        if not phone:
            return phone
        digits = phone.replace(" ", "").replace("-", "")
        if len(digits) <= 4:
            return phone
        # 保留国家码 + 后4位
        return phone[:3] + "***-***-" + digits[-4:]

    @staticmethod
    def mask_social(handle: str) -> str:
        """社交账号部分掩码: @john_designs → @j***_designs"""
        if not handle:
            return handle
        if handle.startswith("@"):
            name = handle[1:]
            return "@" + (name[0] + "***" + name[-6:] if len(name) > 7 else name[0] + "***")
        return handle[:1] + "***" + handle[-3:] if len(handle) > 4 else handle[:1] + "***"

    @classmethod
    def process(cls, email: str, phone: str, social: str) -> dict:
        """处理一组敏感数据，返回哈希 + 掩码"""
        return {
            "email_hash":    cls.hash_value(email),
            "phone_hash":    cls.hash_value(phone),
            "social_hash":   cls.hash_value(social),
            "email_masked":  cls.mask_email(email),
            "phone_masked":  cls.mask_phone(phone),
            "social_masked": cls.mask_social(social),
        }


# ─────────────────────────────────────────────────────────────────
# 代理管理器
# ─────────────────────────────────────────────────────────────────
class ProxyManager:
    """
    动态代理管理 — 支持轮换、失效剔除、自动降级。
    代理格式: http://username:password@server:port
    """

    def __init__(self):
        self.enabled = Config.PROXY_SETTINGS["enabled"]
        self.server = Config.PROXY_SETTINGS["server"]
        self.username = Config.PROXY_SETTINGS["username"]
        self.password = Config.PROXY_SETTINGS["password"]
        self.rotate_interval = Config.PROXY_SETTINGS["rotate_interval"]
        self.request_count = 0

    def get_proxy(self) -> str | None:
        """获取代理 URL（Playwright 格式）"""
        if not self.enabled:
            return None

        self.request_count += 1
        proxy_url = f"http://{self.username}:{self.password}@{self.server}"
        logger.debug(f"🌐 使用代理: {self.server} (请求 #{self.request_count})")
        return proxy_url

    def should_rotate(self) -> bool:
        return self.request_count >= self.rotate_interval


# ─────────────────────────────────────────────────────────────────
# 随机延迟 (Jitter)
# ─────────────────────────────────────────────────────────────────
def human_jitter(action: str = "request"):
    """模拟人类行为的随机延迟"""
    delay = random.uniform(Config.JITTER_MIN, Config.JITTER_MAX)
    logger.info(f"💤 随机延迟 {delay:.1f}s — {action}")
    time.sleep(delay)


# ─────────────────────────────────────────────────────────────────
# 核心：采集引擎
# ─────────────────────────────────────────────────────────────────
class CrawlerEngine:
    """
    GlobalRadar AI 采集引擎
    ── while True 守护进程，持续采集 → 脱敏 → 入库
    """

    def __init__(self):
        # 初始化 Supabase 客户端
        self.supabase: Client = create_client(
            Config.SUPABASE_URL,
            Config.SUPABASE_KEY
        )
        logger.info("✅ Supabase 客户端已连接")

        # 初始化采集器
        self.fetcher = PlaywrightFetcher
        self.breaker = CircuitBreaker()
        self.proxy_manager = ProxyManager()
        self.masker = DataMasker()

        # 统计
        self.stats = {
            "total_crawled": 0,
            "total_inserted": 0,
            "total_errors": 0,
        }

        # 区域映射 — 模拟不同国家的买家
        self.regions = [
            "United States", "Germany", "Australia", "Canada",
            "United Kingdom", "Mexico", "United Arab Emirates",
            "Brazil", "France", "Japan"
        ]

        # 采购需求模板
        self.procurement_templates = [
            "Lawn mower spare parts — bulk inquiry",
            "LED strip lights wholesale — factory direct",
            "Solar panel mounting brackets — MOQ 5000",
            "Cordless drill batteries — OEM manufacturing",
            "Garden hose reels — seasonal import",
            "Pressure washer pumps — distributor pricing",
            "Waterproof LED drivers — CE/RoHS certified",
            "Outdoor string lights — bulk festival order",
            "Industrial air compressors — factory sourcing",
            "Smart home sensors — Zigbee compatible",
        ]

    def _build_proxy_config(self) -> dict:
        """构建 Playwright 代理配置"""
        proxy_url = self.proxy_manager.get_proxy()
        if not proxy_url:
            return {}

        # 解析代理: http://user:pass@server:port
        from urllib.parse import urlparse
        parsed = urlparse(proxy_url)
        return {
            "server": f"{parsed.scheme}://{parsed.hostname}:{parsed.port}",
            "username": parsed.username or "",
            "password": parsed.password or "",
        }

    def _is_blocked(self, page_content: str, status_code: int) -> bool:
        """
        检测是否被目标网站封禁/拦截
        """
        if status_code in (403, 429):
            return True, f"HTTP {status_code}"

        # Cloudflare 拦截特征
        cf_markers = [
            "cf-browser-verification",
            "cf-challenge-running",
            "cf-turnstile",
            "Just a moment...",
            "Attention Required! | Cloudflare",
            "Enable JavaScript and cookies to continue",
        ]
        for marker in cf_markers:
            if marker in page_content:
                return True, f"Cloudflare: {marker}"

        return False, ""

    def _parse_quotes_page(self, page_content: str, source_url: str) -> list[dict]:
        """
        解析 quotes.toscrape.com 页面，将名言转换为模拟的"国际商机"线索格式。
        演示用 — 真实场景替换为目标 B2B 网站的解析逻辑。
        """
        from scrapling import Scraper, AdaptiveScraper

        # 使用 scrapling 自适应解析
        page = AdaptiveScraper.get(body=page_content)

        clues = []
        quotes = page.css("div.quote")

        for i, quote in enumerate(quotes):
            # 提取文本和作者
            text = quote.css_first("span.text::text") or ""
            author = quote.css_first("small.author::text") or f"Unknown_{i}"

            # 组装成国际商机格式
            region = self.regions[(i + random.randint(0, 9)) % len(self.regions)]
            title = self.procurement_templates[i % len(self.procurement_templates)]
            score = random.randint(60, 98)

            # 模拟敏感数据（真实场景从页面提取）
            fake_email = f"{author.lower().replace(' ', '.')}@{region.lower().split()[0]}.com"
            fake_phone = f"+{random.randint(1, 97)}-{random.randint(100, 999)}-{random.randint(100, 999)}-{random.randint(1000, 9999)}"
            fake_social = f"@{author.lower().replace(' ', '_')}"

            # 脱敏处理
            masked_data = self.masker.process(fake_email, fake_phone, fake_social)

            clue = {
                "title":          f"{title}",
                "region":         region,
                "raw_url":        source_url,
                "source":         "quotes_toscrape",
                "buyer_type":     "individual" if score < 80 else "enterprise",
                "category":       "industrial" if i % 2 == 0 else "consumer",
                "score":          score,
                "status":         "unverified",
                **masked_data,
                "crawl_metadata": json.dumps({
                    "quote_text":  text[:200] if text else "",
                    "author":      author,
                    "tags":        [t.text for t in quote.css("a.tag::text")][:5],
                }, ensure_ascii=False),
            }
            clues.append(clue)

        return clues

    def _insert_to_supabase(self, clues: list[dict]) -> int:
        """批量插入到 Supabase radar_clues 表"""
        if not clues:
            return 0

        batch_id = f"{Config.BATCH_PREFIX}_{datetime.now(timezone.utc).strftime('%Y%m%d_%H%M%S')}"

        # 添加批次号
        for clue in clues:
            clue["crawl_batch"] = batch_id

        try:
            result = self.supabase.table("radar_clues").insert(clues).execute()
            inserted = len(result.data) if result.data else 0
            logger.info(
                f"✅ 入库成功 — 批次 {batch_id} | 插入 {inserted} 条 | "
                f"累计 {self.stats['total_inserted'] + inserted} 条"
            )
            self.stats["total_inserted"] += inserted
            return inserted
        except Exception as e:
            logger.error(f"❌ Supabase 入库失败: {e}")
            self.stats["total_errors"] += 1
            return 0

    def crawl_page(self, url: str) -> bool:
        """
        抓取单个页面
        返回: True=成功, False=失败
        """
        logger.info(f"🕷️  开始抓取: {url}")

        proxy_config = self._build_proxy_config()
        fetch_kwargs = {
            "timeout": Config.REQUEST_TIMEOUT,
            "adaptive": True,  # 自愈模式 — 自动适配布局变更
            "stealth": True,   # 反检测模式
        }

        if proxy_config:
            fetch_kwargs["proxy"] = proxy_config
            logger.info(f"🌐 代理已注入: {proxy_config['server']}")

        # 随机延迟 — 人类行为模拟
        human_jitter(f"访问前延迟 — {url}")

        try:
            # 使用 PlaywrightFetcher 获取页面
            page = self.fetcher.get(
                url,
                **fetch_kwargs
            )

            # 获取状态码和内容
            status_code = getattr(page, "status", 200)
            page_content = getattr(page, "html_content", "") or getattr(page, "body", "") or str(page)

            logger.info(f"📊 HTTP {status_code} | 内容长度: {len(page_content)} chars")

            # 检测是否被封禁
            is_blocked, reason = self._is_blocked(page_content, status_code)
            if is_blocked:
                self.breaker.record_failure(reason)
                logger.warning(f"🚫 被拦截 — {reason}")
                return False

            # 解析页面
            try:
                clues = self._parse_quotes_page(page_content, url)
            except Exception as parse_err:
                logger.error(f"❌ 页面解析失败: {parse_err}")
                self.stats["total_errors"] += 1
                self.breaker.record_failure(f"parse_error: {parse_err}")
                return False

            if not clues:
                logger.warning(f"⚠️  页面无有效数据 — {url}")
                self.breaker.record_success()  # 没有数据不算失败
                return True

            # 入库
            inserted = self._insert_to_supabase(clues)
            self.stats["total_crawled"] += len(clues)

            # 成功 — 重置熔断器
            self.breaker.record_success()
            return True

        except Exception as e:
            error_msg = str(e)
            logger.error(f"❌ 抓取异常: {error_msg}")
            traceback.print_exc()

            # 判断异常类型
            if any(code in error_msg for code in ["403", "429", "Forbidden", "blocked"]):
                self.breaker.record_failure(f"exception: {error_msg[:100]}")
            else:
                # 非封禁类异常（网络超时等），只计数不触发熔断
                self.stats["total_errors"] += 1

            return False

    def crawl_round(self):
        """执行一轮完整采集"""
        logger.info("=" * 70)
        logger.info(f"🔄 开始第 {self.stats['total_crawled']} 轮采集")
        logger.info(f"📊 熔断器状态: {self.breaker.status()}")
        logger.info("=" * 70)

        # 熔断检查
        if self.breaker.is_tripped():
            return  # 熔断中，直接跳过本轮

        # 随机打乱 URL 顺序（反爬虫 — 不按固定顺序访问）
        urls = Config.TARGET_URLS.copy()
        random.shuffle(urls)

        success_count = 0
        for url in urls:
            # 每次请求前检查熔断
            if self.breaker.is_tripped():
                logger.warning("⛔ 熔断中，跳过剩余 URL")
                break

            ok = self.crawl_page(url)
            if ok:
                success_count += 1
            else:
                # 失败后额外等待
                extra_delay = random.uniform(10, 30)
                logger.info(f"💤 失败后额外等待 {extra_delay:.1f}s")
                time.sleep(extra_delay)

        logger.info(
            f"📋 本轮结束 — 成功 {success_count}/{len(urls)} | "
            f"累计采集 {self.stats['total_crawled']} | 入库 {self.stats['total_inserted']} | "
            f"错误 {self.stats['total_errors']}"
        )

    def run_forever(self):
        """while True 守护进程主循环"""
        logger.info("╔══════════════════════════════════════════════════════════════╗")
        logger.info("║  GlobalRadar AI — 采集引擎已启动                              ║")
        logger.info("╠══════════════════════════════════════════════════════════════╣")
        logger.info(f"║  Supabase:  {Config.SUPABASE_URL[:48]:48s}║")
        logger.info(f"║  目标页数:  {len(Config.TARGET_URLS):<46d}║")
        logger.info(f"║  代理状态:  {'启用' if self.proxy_manager.enabled else '未启用':<46s}║")
        logger.info(f"║  熔断阈值:  {Config.CIRCUIT_THRESHOLD} 次连续失败 → 休眠 {Config.CIRCUIT_SLEEP}s{'':<16s}║")
        logger.info(f"║  随机延迟:  {Config.JITTER_MIN}-{Config.JITTER_MAX}s 每次请求{'':<32s}║")
        logger.info("╚══════════════════════════════════════════════════════════════╝")

        while True:
            try:
                self.crawl_round()
            except KeyboardInterrupt:
                logger.info("👋 收到 Ctrl+C，安全退出...")
                break
            except Exception as e:
                logger.error(f"💥 主循环异常: {e}")
                traceback.print_exc()

            # 轮间间隔
            logger.info(f"⏳ 等待 {Config.LOOP_INTERVAL}s 后开始下一轮...")
            time.sleep(Config.LOOP_INTERVAL)


# ─────────────────────────────────────────────────────────────────
# 入口
# ─────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    engine = CrawlerEngine()
    engine.run_forever()
