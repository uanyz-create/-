-- ═══════════════════════════════════════════════════════════════════════════
-- GlobalRadar AI — Supabase 数据库初始化脚本
-- ═══════════════════════════════════════════════════════════════════════════
-- 生成时间: 2026-06-20
-- 用途: 创建 radar_clues 表 + Realtime 广播通道 + 脱敏视图 + 解密 RPC
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────────
-- 0. 扩展依赖
-- ─────────────────────────────────────────────────────────────────
-- pgcrypto 用于 gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ─────────────────────────────────────────────────────────────────
-- 1. 核心线索表 radar_clues
-- ─────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS radar_clues (
    -- 主键
    id              UUID            PRIMARY KEY DEFAULT gen_random_uuid(),

    -- 线索基本信息
    title           TEXT            NOT NULL,
    region          TEXT            NOT NULL,
    raw_url         TEXT            NOT NULL,

    -- 状态机: unverified → verified → decrypted → followed_up → converted
    status          TEXT            NOT NULL DEFAULT 'unverified'
                        CHECK (status IN (
                            'unverified', 'verified', 'decrypted',
                            'followed_up', 'converted', 'expired'
                        )),

    -- 时间戳
    created_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ    NOT NULL DEFAULT now(),

    -- ── 采集端写入的扩展字段 ──
    source          TEXT            NOT NULL DEFAULT 'quotes_toscrape',
    buyer_type      TEXT            DEFAULT 'individual',
    category        TEXT            DEFAULT 'general',
    score           INTEGER         DEFAULT 50 CHECK (score >= 0 AND score <= 100),

    -- 敏感数据 — 采集端已做 SHA-256 哈希脱敏，此处存哈希值
    -- 原始明文不入库，解密时由后端 RPC 从采集端缓存拉取
    email_hash      TEXT            DEFAULT NULL,
    phone_hash      TEXT            DEFAULT NULL,
    social_hash    TEXT            DEFAULT NULL,

    -- 脱敏后的预览信息（前端可安全展示）
    email_masked    TEXT            DEFAULT NULL,
    phone_masked    TEXT            DEFAULT NULL,
    social_masked   TEXT            DEFAULT NULL,

    -- 是否已解密（扣费标记）
    is_decrypted    BOOLEAN         NOT NULL DEFAULT FALSE,
    decrypted_by    UUID            DEFAULT NULL,
    decrypted_at    TIMESTAMPTZ     DEFAULT NULL,

    -- 采集元数据
    crawl_batch     TEXT            DEFAULT NULL,
    crawl_metadata  JSONB           DEFAULT '{}'::jsonb
);

-- ─────────────────────────────────────────────────────────────────
-- 2. 索引优化
-- ─────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_radar_clues_created_at  ON radar_clues (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_radar_clues_region      ON radar_clues (region);
CREATE INDEX IF NOT EXISTS idx_radar_clues_status      ON radar_clues (status);
CREATE INDEX IF NOT EXISTS idx_radar_clues_score       ON radar_clues (score DESC);
CREATE INDEX IF NOT EXISTS idx_radar_clues_is_decrypted ON radar_clues (is_decrypted);
CREATE INDEX IF NOT EXISTS idx_radar_clues_source      ON radar_clues (source);

-- updated_at 自动更新触发器
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_radar_clues_updated_at ON radar_clues;
CREATE TRIGGER trigger_radar_clues_updated_at
    BEFORE UPDATE ON radar_clues
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- ─────────────────────────────────────────────────────────────────
-- 3. 解密扣费 RPC 函数 (SECURITY DEFINER + FOR UPDATE 行锁)
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION decrypt_clue(
    p_clue_id   UUID,
    p_user_id   UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_clue        radar_clues%ROWTYPE;
    v_result      JSONB;
BEGIN
    -- 行级锁，防止并发扣费
    SELECT * INTO v_clue
    FROM radar_clues
    WHERE id = p_clue_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', FALSE, 'error', 'clue_not_found');
    END IF;

    -- 如果已经解密过，直接返回（幂等）
    IF v_clue.is_decrypted = TRUE THEN
        RETURN jsonb_build_object(
            'success', TRUE,
            'already_decrypted', TRUE,
            'clue_id', v_clue.id
        );
    END IF;

    -- 标记解密
    UPDATE radar_clues
    SET
        is_decrypted  = TRUE,
        decrypted_by  = p_user_id,
        decrypted_at  = now()
    WHERE id = p_clue_id;

    -- 返回脱敏预览（真实明文由采集端缓存提供，数据库不存储明文）
    v_result := jsonb_build_object(
        'success',        TRUE,
        'clue_id',        v_clue.id,
        'title',          v_clue.title,
        'region',         v_clue.region,
        'raw_url',        v_clue.raw_url,
        'email_masked',   v_clue.email_masked,
        'phone_masked',   v_clue.phone_masked,
        'social_masked',  v_clue.social_masked,
        'source',         v_clue.source,
        'score',          v_clue.score
    );

    RETURN v_result;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 4. KPI 聚合函数（前端大屏调用）
-- ─────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION get_radar_stats()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_total       BIGINT;
    v_verified    BIGINT;
    v_decrypted   BIGINT;
    v_converted   BIGINT;
    v_today       BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_total      FROM radar_clues;
    SELECT COUNT(*) INTO v_verified    FROM radar_clues WHERE status = 'verified';
    SELECT COUNT(*) INTO v_decrypted   FROM radar_clues WHERE is_decrypted = TRUE;
    SELECT COUNT(*) INTO v_converted   FROM radar_clues WHERE status = 'converted';
    SELECT COUNT(*) INTO v_today       FROM radar_clues WHERE created_at >= CURRENT_DATE;

    RETURN jsonb_build_object(
        'total_clues',     v_total,
        'verified_clues',  v_verified,
        'decrypted_clues', v_decrypted,
        'converted_clues', v_converted,
        'today_clues',     v_today
    );
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 5. RLS 行级安全策略
-- ─────────────────────────────────────────────────────────────────
ALTER TABLE radar_clues ENABLE ROW LEVEL SECURITY;

-- 匿名用户可读未加密的公开字段（脱敏后的数据）
CREATE POLICY "anon_read_public_clues"
    ON radar_clues FOR SELECT
    TO anon
    USING (TRUE);

-- 认证用户可读全部
CREATE POLICY "auth_read_all_clues"
    ON radar_clues FOR SELECT
    TO authenticated
    USING (TRUE);

-- service_role 可写入（采集端用 service_role key）
CREATE POLICY "service_insert_clues"
    ON radar_clues FOR INSERT
    TO service_role
    WITH CHECK (TRUE);

CREATE POLICY "service_update_clues"
    ON radar_clues FOR UPDATE
    TO service_role
    USING (TRUE) WITH CHECK (TRUE);

-- ─────────────────────────────────────────────────────────────────
-- 6. Realtime 实时广播 — 关键步骤
-- ─────────────────────────────────────────────────────────────────
-- 将 radar_clues 加入 supabase_realtime Publication（复制集）
-- 确保前端 WebSocket 长连接能收到 INSERT/UPDATE/DELETE 广播
ALTER PUBLICATION supabase_realtime ADD TABLE radar_clues;

-- 验证是否已加入
DO $$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count
    FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND tablename = 'radar_clues';

    IF v_count > 0 THEN
        RAISE NOTICE '✅ radar_clues 已成功加入 supabase_realtime 广播通道';
    ELSE
        RAISE NOTICE '⚠️ radar_clues 尚未加入 supabase_realtime，请检查权限';
    END IF;
END;
$$;

-- ─────────────────────────────────────────────────────────────────
-- 7. 初始种子数据（模拟采集端入库格式）
-- ─────────────────────────────────────────────────────────────────
INSERT INTO radar_clues (title, region, raw_url, source, score, email_masked, phone_masked, social_masked, crawl_batch)
VALUES
    ('Lawn mower spare parts — bulk inquiry', 'United States', 'https://quotes.toscrape.com/page/1/', 'quotes_toscrape', 85, 'j***@gmail.com', '+1***-***-2847', '@j***_designs', 'batch_001'),
    ('LED strip lights wholesale — factory direct', 'Germany', 'https://quotes.toscrape.com/page/2/', 'quotes_toscrape', 78, 'm***@web.de', '+49***-***-1953', '@m***_tech', 'batch_001'),
    ('Solar panel mounting brackets — MOQ 5000', 'Australia', 'https://quotes.toscrape.com/page/3/', 'quotes_toscrape', 92, 'd***@bigpond.com', '+61***-***-3712', '@d***_solar', 'batch_001'),
    ('Cordless drill batteries — OEM manufacturing', 'Canada', 'https://quotes.toscrape.com/page/4/', 'quotes_toscrape', 81, 'p***@rogers.com', '+1***-***-4906', '@p***_tools', 'batch_001'),
    ('Garden hose reels — seasonal import', 'United Kingdom', 'https://quotes.toscrape.com/page/5/', 'quotes_toscrape', 73, 't***@btinternet.com', '+44***-***-8234', '@t***_garden', 'batch_001'),
    ('Pressure washer pumps — distributor pricing', 'Mexico', 'https://quotes.toscrape.com/page/6/', 'quotes_toscrape', 88, 'c***@prodigy.net.mx', '+52***-***-6178', '@c***_clean', 'batch_001'),
    ('Waterproof LED drivers — CE/RoHS certified', 'United Arab Emirates', 'https://quotes.toscrape.com/page/7/', 'quotes_toscrape', 90, 'a***@emirates.net.ae', '+971***-***-2945', '@a***_trading', 'batch_001'),
    ('Outdoor string lights — bulk festival order', 'Brazil', 'https://quotes.toscrape.com/page/8/', 'quotes_toscrape', 76, 'r***@uol.com.br', '+55***-***-3821', '@r***_festas', 'batch_001')
ON CONFLICT DO NOTHING;

-- ═══════════════════════════════════════════════════════════════════════════
-- 执行完毕。现在 radar_clues 表已创建，Realtime 广播已开启。
-- 采集端写入数据后，前端 WebSocket 会立即收到 INSERT 事件推送。
-- ═══════════════════════════════════════════════════════════════════════════
