-- ============================================================
-- 出海雷达 AI - Supabase 完整 Schema
-- 执行前请确保已启用 pg_cron 和 uuid-ossp 扩展
-- ============================================================

-- 启用扩展
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_cron";

-- ============================================================
-- 1. 基础表结构
-- ============================================================

-- profiles 用户档案
CREATE TABLE IF NOT EXISTS profiles (
  id uuid REFERENCES auth.users ON DELETE CASCADE PRIMARY KEY,
  email text UNIQUE NOT NULL,
  membership_level text NOT NULL DEFAULT '基础版' CHECK (membership_level IN ('基础版', '专业版', '企业版')),
  company_name text,
  industry text,
  last_recharge_at timestamptz,
  created_at timestamptz DEFAULT now()
);

-- user_credits 用户积分/余额
CREATE TABLE IF NOT EXISTS user_credits (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE UNIQUE NOT NULL,
  daily_free_used int NOT NULL DEFAULT 0,
  wallet_balance numeric(10, 2) NOT NULL DEFAULT 0.00,
  daily_reset_at date NOT NULL DEFAULT CURRENT_DATE,
  updated_at timestamptz DEFAULT now()
);

-- radar_clues 采购线索（不设RLS，通过RPC访问）
CREATE TABLE IF NOT EXISTS radar_clues (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  community text NOT NULL CHECK (community IN ('Facebook', 'Reddit', 'LinkedIn', 'Twitter', 'Alibaba', 'IndiaMART', 'TradeKey')),
  author text NOT NULL,
  avatar_url text,
  title text NOT NULL,
  excerpt text NOT NULL,
  full_text text NOT NULL,
  country text NOT NULL,
  country_flag text,
  url text NOT NULL,
  keyword_tags text[] DEFAULT '{}',
  budget_range text,
  moq text,
  certification_required text,
  port_info text,
  match_score int DEFAULT 75 CHECK (match_score BETWEEN 0 AND 100),
  created_at timestamptz DEFAULT now()
);

-- clues_history 解密记录（审计表）
CREATE TABLE IF NOT EXISTS clues_history (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  clue_id uuid REFERENCES radar_clues(id) NOT NULL,
  decrypted_text text,
  ai_script_generated text,
  buyer_insight jsonb,
  cost_amount numeric(10, 2) NOT NULL DEFAULT 0,
  tone_level int DEFAULT 2 CHECK (tone_level BETWEEN 1 AND 4),
  created_at timestamptz DEFAULT now()
);

-- wallet_transactions 钱包流水
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  amount numeric(10, 2) NOT NULL,
  balance_snapshot numeric(10, 2) NOT NULL,
  type text NOT NULL CHECK (type IN ('recharge', 'consume', 'refund', 'bonus')),
  description text,
  order_id text,
  created_at timestamptz DEFAULT now()
);

-- script_versions AI话术版本
CREATE TABLE IF NOT EXISTS script_versions (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  clue_id uuid REFERENCES radar_clues(id) NOT NULL,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  version int NOT NULL DEFAULT 1,
  content text NOT NULL,
  tone_level int NOT NULL DEFAULT 2 CHECK (tone_level BETWEEN 1 AND 4),
  word_count int,
  created_at timestamptz DEFAULT now()
);

-- user_roles 角色权限
CREATE TABLE IF NOT EXISTS user_roles (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE UNIQUE NOT NULL,
  role text NOT NULL DEFAULT 'user' CHECK (role IN ('admin', 'user', 'moderator')),
  created_at timestamptz DEFAULT now()
);

-- risk_alerts 风控记录
CREATE TABLE IF NOT EXISTS risk_alerts (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE,
  ip_address inet,
  alert_type text NOT NULL CHECK (alert_type IN ('rate_limit_account', 'rate_limit_ip', 'suspicious_activity', 'balance_fraud')),
  request_count int,
  window_seconds int DEFAULT 60,
  metadata jsonb,
  created_at timestamptz DEFAULT now()
);

-- user_cooldowns 用户冷却
CREATE TABLE IF NOT EXISTS user_cooldowns (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  user_id uuid REFERENCES profiles(id) ON DELETE CASCADE NOT NULL,
  reason text,
  cooldown_until timestamptz NOT NULL,
  created_by text DEFAULT 'system',
  created_at timestamptz DEFAULT now()
);

-- risk_config 风控配置（管理员可调）
CREATE TABLE IF NOT EXISTS risk_config (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  config_key text UNIQUE NOT NULL,
  config_value text NOT NULL,
  description text,
  updated_at timestamptz DEFAULT now()
);

INSERT INTO risk_config (config_key, config_value, description) VALUES
  ('account_rate_limit', '20', '账号级：60秒内最多请求次数'),
  ('ip_rate_limit', '40', 'IP级：60秒内最多请求次数'),
  ('free_daily_limit', '5', '每日免费解密次数'),
  ('cost_per_decrypt', '0.5', '超额每次解密费用（元）'),
  ('min_recharge_amount', '10', '最低充值金额（元）')
ON CONFLICT (config_key) DO NOTHING;

-- ============================================================
-- 2. RLS 行级安全策略
-- ============================================================

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_credits ENABLE ROW LEVEL SECURITY;
ALTER TABLE clues_history ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallet_transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE script_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE risk_alerts ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_cooldowns ENABLE ROW LEVEL SECURITY;

-- profiles policies
CREATE POLICY "users_read_own_profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "users_update_own_profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "admin_all_profiles" ON profiles FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- user_credits policies
CREATE POLICY "users_read_own_credits" ON user_credits FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "admin_all_credits" ON user_credits FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- clues_history policies
CREATE POLICY "users_read_own_history" ON clues_history FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "admin_all_history" ON clues_history FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- wallet_transactions policies
CREATE POLICY "users_read_own_transactions" ON wallet_transactions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "admin_all_transactions" ON wallet_transactions FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- script_versions policies
CREATE POLICY "users_manage_own_scripts" ON script_versions FOR ALL USING (auth.uid() = user_id);
CREATE POLICY "admin_all_scripts" ON script_versions FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- user_roles policies
CREATE POLICY "users_read_own_role" ON user_roles FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "admin_manage_roles" ON user_roles FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- risk_alerts policies
CREATE POLICY "admin_all_risk_alerts" ON risk_alerts FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- user_cooldowns policies
CREATE POLICY "users_read_own_cooldown" ON user_cooldowns FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "admin_all_cooldowns" ON user_cooldowns FOR ALL USING (
  EXISTS (SELECT 1 FROM user_roles WHERE user_id = auth.uid() AND role = 'admin')
);

-- ============================================================
-- 3. 核心 RPC 函数（SECURITY DEFINER）
-- ============================================================

-- 获取脱敏线索列表
CREATE OR REPLACE FUNCTION get_radar_feed(p_keyword text DEFAULT '', p_limit int DEFAULT 20, p_offset int DEFAULT 0)
RETURNS TABLE (
  id uuid, community text, title text, excerpt text, country text, country_flag text,
  keyword_tags text[], budget_range text, moq text, certification_required text,
  port_info text, match_score int, created_at timestamptz,
  author_masked text, avatar_masked text, url_masked text
)
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  RETURN QUERY
  SELECT
    rc.id, rc.community, rc.title, rc.excerpt, rc.country, rc.country_flag,
    rc.keyword_tags, rc.budget_range, rc.moq, rc.certification_required,
    rc.port_info, rc.match_score, rc.created_at,
    -- 马赛克处理：用*代替作者名
    CONCAT(LEFT(rc.author, 1), REPEAT('*', GREATEST(LENGTH(rc.author) - 2, 3)), RIGHT(rc.author, 1)) AS author_masked,
    -- 头像用占位图
    'https://api.dicebear.com/7.x/identicon/svg?seed=' || rc.id::text AS avatar_masked,
    -- URL脱敏
    SPLIT_PART(rc.url, '/', 3) || '/***' AS url_masked
  FROM radar_clues rc
  WHERE
    p_keyword = '' OR
    rc.title ILIKE '%' || p_keyword || '%' OR
    rc.excerpt ILIKE '%' || p_keyword || '%' OR
    rc.full_text ILIKE '%' || p_keyword || '%' OR
    p_keyword = ANY(rc.keyword_tags) OR
    rc.country ILIKE '%' || p_keyword || '%'
  ORDER BY rc.match_score DESC, rc.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$$;

-- 解密线索（原子化，含扣费）
CREATE OR REPLACE FUNCTION decrypt_clue(p_clue_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_credits record;
  v_clue record;
  v_cost numeric := 0;
  v_daily_limit int;
  v_cost_per numeric;
  v_in_cooldown boolean := false;
BEGIN
  -- 检查用户是否登录
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED', 'message', '请先登录');
  END IF;

  -- 检查冷却状态
  SELECT EXISTS(
    SELECT 1 FROM user_cooldowns 
    WHERE user_id = v_user_id AND cooldown_until > now()
  ) INTO v_in_cooldown;
  
  IF v_in_cooldown THEN
    RETURN jsonb_build_object('success', false, 'error', 'COOLDOWN', 'message', '账号已被限流，请稍后再试');
  END IF;

  -- 获取风控配置
  SELECT (SELECT config_value::int FROM risk_config WHERE config_key = 'free_daily_limit') INTO v_daily_limit;
  SELECT (SELECT config_value::numeric FROM risk_config WHERE config_key = 'cost_per_decrypt') INTO v_cost_per;
  
  -- 加行锁获取用户积分
  SELECT * FROM user_credits WHERE user_id = v_user_id FOR UPDATE INTO v_credits;
  
  IF v_credits IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NO_CREDITS', 'message', '用户积分记录不存在');
  END IF;

  -- 重置每日额度（跨天）
  IF v_credits.daily_reset_at < CURRENT_DATE THEN
    UPDATE user_credits SET daily_free_used = 0, daily_reset_at = CURRENT_DATE WHERE user_id = v_user_id;
    v_credits.daily_free_used := 0;
  END IF;

  -- 判断免费/付费
  IF v_credits.daily_free_used < v_daily_limit THEN
    -- 免费额度内
    v_cost := 0;
    UPDATE user_credits SET daily_free_used = daily_free_used + 1 WHERE user_id = v_user_id;
  ELSE
    -- 超额，检查钱包
    v_cost := v_cost_per;
    IF v_credits.wallet_balance < v_cost THEN
      RETURN jsonb_build_object('success', false, 'error', 'INSUFFICIENT_BALANCE', 
        'message', '余额不足，请充值', 'balance', v_credits.wallet_balance);
    END IF;
    -- 扣费
    UPDATE user_credits 
    SET wallet_balance = wallet_balance - v_cost, updated_at = now()
    WHERE user_id = v_user_id;
    -- 写流水
    INSERT INTO wallet_transactions (user_id, amount, balance_snapshot, type, description)
    VALUES (v_user_id, -v_cost, v_credits.wallet_balance - v_cost, 'consume', '解密线索: ' || p_clue_id::text);
  END IF;

  -- 获取完整线索
  SELECT * FROM radar_clues WHERE id = p_clue_id INTO v_clue;
  IF v_clue IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'NOT_FOUND', 'message', '线索不存在');
  END IF;

  -- 写解密记录
  INSERT INTO clues_history (user_id, clue_id, decrypted_text, cost_amount)
  VALUES (v_user_id, p_clue_id, v_clue.full_text, v_cost);

  -- 返回明文数据
  RETURN jsonb_build_object(
    'success', true,
    'author', v_clue.author,
    'avatar_url', v_clue.avatar_url,
    'url', v_clue.url,
    'full_text', v_clue.full_text,
    'cost', v_cost
  );
END;
$$;

-- 模拟支付宝充值订单
CREATE OR REPLACE FUNCTION create_alipay_order(p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_order_id text;
  v_min_amount numeric;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  
  SELECT config_value::numeric FROM risk_config WHERE config_key = 'min_recharge_amount' INTO v_min_amount;
  
  IF p_amount < v_min_amount THEN
    RETURN jsonb_build_object('success', false, 'error', 'AMOUNT_TOO_LOW', 'min', v_min_amount);
  END IF;
  
  v_order_id := 'ORD-' || TO_CHAR(now(), 'YYYYMMDD') || '-' || UPPER(SUBSTRING(uuid_generate_v4()::text, 1, 8));
  
  RETURN jsonb_build_object(
    'success', true,
    'order_id', v_order_id,
    'amount', p_amount,
    'qr_content', 'alipay://pay?order_id=' || v_order_id || '&amount=' || p_amount,
    'expires_at', (now() + interval '15 minutes')::text
  );
END;
$$;

-- 确认支付（模拟）
CREATE OR REPLACE FUNCTION confirm_alipay_payment(p_order_id text, p_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER AS $$
DECLARE
  v_user_id uuid := auth.uid();
  v_new_balance numeric;
BEGIN
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'UNAUTHENTICATED');
  END IF;
  
  UPDATE user_credits
  SET wallet_balance = wallet_balance + p_amount, updated_at = now()
  WHERE user_id = v_user_id
  RETURNING wallet_balance INTO v_new_balance;
  
  INSERT INTO wallet_transactions (user_id, amount, balance_snapshot, type, description, order_id)
  VALUES (v_user_id, p_amount, v_new_balance, 'recharge', '支付宝充值', p_order_id);
  
  UPDATE profiles SET last_recharge_at = now() WHERE id = v_user_id;
  
  RETURN jsonb_build_object('success', true, 'new_balance', v_new_balance, 'order_id', p_order_id);
END;
$$;

-- 注册时自动创建档案和积分记录
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
  INSERT INTO profiles (id, email) VALUES (NEW.id, NEW.email);
  INSERT INTO user_credits (user_id) VALUES (NEW.id);
  
  -- 管理员自动提权
  IF NEW.email = 'oraora2026@163.com' THEN
    INSERT INTO user_roles (user_id, role) VALUES (NEW.id, 'admin');
  ELSE
    INSERT INTO user_roles (user_id, role) VALUES (NEW.id, 'user');
  END IF;
  
  RETURN NEW;
END;
$$;

CREATE OR REPLACE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- ============================================================
-- 4. pg_cron 定时任务：每日00:00重置免费额度（Asia/Shanghai）
-- ============================================================

SELECT cron.schedule(
  'reset-daily-free-credits',
  '0 16 * * *', -- UTC 16:00 = 北京时间 00:00
  $$UPDATE user_credits SET daily_free_used = 0, daily_reset_at = CURRENT_DATE WHERE daily_reset_at < CURRENT_DATE;$$
);

-- ============================================================
-- 5. 种子数据：60+ 条多语种采购线索
-- ============================================================

INSERT INTO radar_clues (community, author, avatar_url, title, excerpt, full_text, country, country_flag, url, keyword_tags, budget_range, moq, certification_required, port_info, match_score) VALUES

-- ===== 割草机 / Lawn Mower 专项线索（8条，美/德/加/澳/英/墨/阿联酋）=====
('Reddit', 'Mike_Tennessee', 'https://i.pravatar.cc/150?img=1', 'Looking for riding lawn mower manufacturer from China - urgent order', 'We need 500 units of riding lawn mowers for Spring season. EPA and CARB certification mandatory. Los Angeles port preferred.', 'Hi, I am procurement manager at a landscaping equipment company in Tennessee. We are looking for a reliable Chinese manufacturer for riding lawn mowers. Requirement: 500 units minimum first order, must have EPA and CARB certification for US market. Engine 20HP+, cut width 42-54 inch. Budget $350-450 per unit FOB. Prefer Los Angeles port. Please send catalog and factory audit report.', 'United States', '🇺🇸', 'https://reddit.com/r/lawncare/comments/abc123', ARRAY['割草机', 'lawn mower', 'riding mower', 'EPA'], '$175,000-$225,000', '500 units', 'EPA, CARB', 'Los Angeles Port', 97),

('Facebook', 'Hans_Mueller', 'https://i.pravatar.cc/150?img=2', 'Rasenmäher Großhandel gesucht - Zertifizierung CE erforderlich', 'Wir suchen einen chinesischen Hersteller für Rasenmäher mit CE-Zertifizierung für den deutschen Markt. MOQ 200 Stück.', 'Guten Tag, ich bin Einkäufer bei einem Gartengerät-Großhändler in München. Wir suchen einen zuverlässigen chinesischen Lieferanten für Aufsitzrasenmäher und Elektro-Rasenmäher. Bedingungen: CE-Zertifizierung Pflicht, GS-Zeichen bevorzugt, MOQ 200 Stück, Budget €180-250/Stück CIF Hamburg. Bitte schicken Sie Produktkatalog und CE-Zertifikate. Hamburg oder Bremerhaven Hafen.', 'Germany', '🇩🇪', 'https://facebook.com/groups/gartengeraete/posts/def456', ARRAY['割草机', 'Rasenmäher', 'lawn mower', 'CE'], '€36,000-€50,000', '200 units', 'CE, GS', 'Hamburg Port', 95),

('LinkedIn', 'James_Calgary', 'https://i.pravatar.cc/150?img=3', 'Lawn mower supplier wanted - Canada market - CSA certified only', 'Canadian distributor seeking OEM lawn mower manufacturer. Must have CSA certification. 300 units MOQ. Vancouver port preferred.', 'Hello, I represent a major outdoor power equipment distributor in Calgary, Canada. We are expanding our lawn mower product line and seeking an OEM manufacturer from China. Strict requirements: CSA certification for Canada market, engines must meet emission standards. MOQ 300 units, budget CAD $280-380/unit. Delivery to Vancouver port. Please provide factory photos, certifications, and sample availability.', 'Canada', '🇨🇦', 'https://linkedin.com/posts/jcalgary_lawnmower', ARRAY['lawn mower', 'CSA', '割草机', 'OEM'], 'CAD $84,000-$114,000', '300 units', 'CSA', 'Vancouver Port', 94),

('Reddit', 'AussieGardenPro', 'https://i.pravatar.cc/150?img=4', 'Need Australian standard lawn mower from China - Bunnings supplier opportunity', 'Large order for Australian retail chain. SAA/RCM certification required. Sydney or Melbourne port. Budget AUD 300-450/unit.', 'G day! I am sourcing manager for a major garden equipment retailer in Australia. We need to source quality lawn mowers from China for our stores. Requirements: SAA/RCM certification mandatory for Australian market, EESS compliance, MOQ 400 units, budget AUD 300-450 per unit. Prefer FCL container shipping to Sydney or Melbourne. Need factory audit capability. Contact me if you can meet specs.', 'Australia', '🇦🇺', 'https://reddit.com/r/ausfinance/comments/ghi789', ARRAY['lawn mower', '割草机', 'SAA', 'RCM', 'Australia'], 'AUD $120,000-$180,000', '400 units', 'SAA, RCM, EESS', 'Sydney Port', 93),

('Facebook', 'GardenKing_UK', 'https://i.pravatar.cc/150?img=5', 'UK lawn mower importer seeking Chinese factory partner - UKCA certified', 'We import garden machinery to UK. Need lawn mower factory with UKCA certification post-Brexit. MOQ 250 units. Felixstowe port.', 'Hello from London! Our company imports garden power tools across UK. Post-Brexit we now need UKCA certification (not just CE). Seeking Chinese lawn mower manufacturer: electric and petrol models, self-propelled, MOQ 250 units combined, FOB price GBP 120-180/unit. Must have UKCA mark, RoHS compliance. Felixstowe or Southampton port. Interested manufacturers please send quotation and certifications.', 'United Kingdom', '🇬🇧', 'https://facebook.com/marketplace/item/jkl012', ARRAY['lawn mower', 'UKCA', '割草机', 'UK import'], 'GBP £30,000-£45,000', '250 units', 'UKCA, RoHS', 'Felixstowe Port', 92),

('LinkedIn', 'Carlos_Guadalajara', 'https://i.pravatar.cc/150?img=6', 'Búsqueda urgente: proveedor de cortadoras de césped para México - NOM certificación', 'Empresa mexicana busca fabricante chino de cortadoras de césped con certificación NOM-016. Pedido mínimo 200 unidades. Puerto de Manzanillo.', 'Hola, soy gerente de compras de una empresa distribuidora de equipos de jardinería en Guadalajara, México. Necesitamos urgentemente un proveedor chino de cortadoras de césped. Requisitos obligatorios: certificación NOM-016-ENER-2016, etiquetado en español, MOQ 200 unidades, precio FOB USD 180-260/unidad. Puerto de destino Manzanillo o Lázaro Cárdenas. Por favor enviar catálogo, certificaciones y disponibilidad de muestras.', 'Mexico', '🇲🇽', 'https://linkedin.com/posts/carlos_mex_lawnmower', ARRAY['cortadora de cesped', '割草机', 'lawn mower', 'NOM', 'Mexico'], '$36,000-$52,000', '200 units', 'NOM-016', 'Manzanillo Port', 90),

('Reddit', 'Dubai_Outdoor', 'https://i.pravatar.cc/150?img=7', 'UAE landscaping company needs electric lawn mowers from China - ESMA approved', 'Dubai-based landscaping firm seeking 150+ electric lawn mowers. ESMA certification required. Port of Jebel Ali.', 'Hello, our landscaping company operates across Dubai and Abu Dhabi. We are replacing our gas mowers with electric models. Sourcing from China: electric lawn mowers, self-propelled, battery 40V+, runtime 45min+. ESMA certification required for UAE market. MOQ 150 units, budget USD 200-300/unit. Shipping to Jebel Ali Port. Can visit Canton Fair or arrange video inspection. Serious inquiries only.', 'UAE', '🇦🇪', 'https://reddit.com/r/dubai/comments/mno345', ARRAY['lawn mower', '割草机', 'electric', 'ESMA', 'UAE'], '$30,000-$45,000', '150 units', 'ESMA', 'Jebel Ali Port', 91),

-- ===== 其他割草机相关线索 =====
('Facebook', 'FarmEquip_Iowa', 'https://i.pravatar.cc/150?img=8', 'Farm equipment dealer seeking commercial zero-turn mowers manufacturer', 'Iowa farm equipment dealer needs zero-turn mowers. 200 unit order. EPA Tier 4 engine required.', 'We are a farm equipment dealer in Iowa supplying to professional landscapers. Looking for Chinese manufacturers of commercial zero-turn mowers. Must have EPA Tier 4 engines, 52-72 inch deck width, commercial grade. MOQ 200 units. Budget $1,200-1,800/unit FOB. Can arrange factory visit. Send specs to our procurement team.', 'United States', '🇺🇸', 'https://facebook.com/groups/farmequipment/posts/pqr678', ARRAY['zero-turn mower', '割草机', 'EPA Tier 4', 'commercial'], '$240,000-$360,000', '200 units', 'EPA Tier 4', 'Houston Port', 88),

-- ===== 其他品类线索（补齐60条）=====
('Reddit', 'SolarBuyer_Texas', 'https://i.pravatar.cc/150?img=9', 'Wholesale solar panels needed - 500kW project - UL certification required', 'Texas energy company seeking solar panel supplier for 500kW installation. UL, MCS certification. Price under $0.28/W.', 'We are developing a 500kW commercial solar project in Texas. Need Tier-1 solar panels: monocrystalline, 400W+, UL certification mandatory, 25-year linear output warranty. Looking for 1,250+ panels at under $0.28/W. FOB Shenzhen or Shanghai. Please provide data sheets, certifications, and bankability documentation.', 'United States', '🇺🇸', 'https://reddit.com/r/solar/comments/stu901', ARRAY['solar panel', '太阳能板', 'UL', '光伏'], '$350,000+', '1,250 panels', 'UL, IEC 61215', 'Los Angeles Port', 92),

('LinkedIn', 'EV_Charger_Germany', 'https://i.pravatar.cc/150?img=10', 'EV charging station supplier for European market - TÜV certified', 'German EV infrastructure company seeking Chinese OEM for 7kW and 22kW AC chargers. CE, TÜV certification. OCPP 1.6+.', 'Guten Tag! We are building EV charging networks across Germany and Austria. Need OEM Chinese manufacturer for AC chargers: 7kW single-phase and 22kW three-phase. Requirements: CE, TÜV certification, OCPP 1.6 protocol, IP55, Type 2 connector. MOQ 500 units, budget €180-280/unit. Hamburg delivery. We provide branding and firmware customization.', 'Germany', '🇩🇪', 'https://linkedin.com/posts/ev_charger_de', ARRAY['EV charger', '充电桩', 'TÜV', 'OCPP'], '€90,000-€140,000', '500 units', 'CE, TÜV', 'Hamburg Port', 94),

('Facebook', 'LED_Wholesale_AU', 'https://i.pravatar.cc/150?img=11', 'Australian LED lighting importer - SAA certified bulk order', 'Sydney lighting distributor needs 10,000 LED bulbs and 500 LED strips. SAA/RCM certification. Competitive pricing required.', 'Hi, Sydney-based lighting wholesaler here. We supply to hardware chains and electrical contractors. Need bulk order: 10,000 pcs LED bulbs (E27, 9W, 3000K/6000K), 500 rolls LED strip lights. SAA/RCM certification mandatory. Budget AUD 1.20-1.80/bulb, AUD 8-12/5m roll. FOB Shenzhen. 40ft container. Regular orders quarterly if quality consistent.', 'Australia', '🇦🇺', 'https://facebook.com/groups/ausimp/posts/vwx234', ARRAY['LED', 'lighting', 'SAA', '灯具'], 'AUD $20,000-$35,000', '10,000 pcs', 'SAA, RCM', 'Sydney Port', 89),

('Reddit', 'Furniture_Canada', 'https://i.pravatar.cc/150?img=12', 'Office furniture wholesale from China - BIFMA certification needed', 'Toronto furniture retailer seeking standing desks and ergonomic chairs. BIFMA certification. 200 sets minimum order.', 'Hey, I run an office furniture company in Toronto. Looking to source standing desks and ergonomic office chairs from China. Requirements: BIFMA G1 certified for chairs, desks with electric height adjustment (28-48 inch range), weight capacity 200 lbs+. MOQ 200 sets. Budget CAD $150-200 for chairs, CAD $280-350 for desks. Ship to Toronto or Montreal. Samples required before full order.', 'Canada', '🇨🇦', 'https://reddit.com/r/furnituremaking/comments/yza567', ARRAY['office furniture', 'standing desk', 'ergonomic', 'BIFMA'], 'CAD $86,000-$110,000', '200 sets', 'BIFMA G1', 'Toronto Port', 85),

('LinkedIn', 'Medical_Device_UK', 'https://i.pravatar.cc/150?img=13', 'UK medical device importer seeking pulse oximeters - CE MDR certified', 'NHS supplier looking for pulse oximeters and blood pressure monitors. CE MDR 2017/745 certification mandatory.', 'Hello, we supply medical devices to NHS trusts and private clinics in UK. Seeking Chinese manufacturer for: 1. Fingertip pulse oximeters (10,000 units, SpO2 accuracy ±2%), 2. Upper arm blood pressure monitors (5,000 units, clinically validated). CE MDR 2017/745 mandatory, UK MHRA registration required. Budget: oximeters £8-12/unit, BP monitors £25-35/unit. We provide own branding.', 'United Kingdom', '🇬🇧', 'https://linkedin.com/posts/medical_uk_import', ARRAY['medical device', '医疗设备', 'pulse oximeter', 'CE MDR'], '£205,000-£295,000', '15,000 units', 'CE MDR, MHRA', 'Heathrow', 96),

('Facebook', 'Textile_France', 'https://i.pravatar.cc/150?img=14', 'Paris fashion brand seeking organic cotton manufacturer - GOTS certified', 'French clothing brand needs GOTS certified organic cotton fabric and garments. 500kg fabric minimum. Lyon distribution.', 'Bonjour! Marque de mode parisienne cherche fournisseur chinois de tissu coton biologique certifié GOTS. Nous avons besoin: 500kg minimum tissu coton bio (210g/m², différents coloris), MOQ vêtements 100 pcs/coloris. Certification GOTS obligatoire, OEKO-TEX STANDARD 100 apprécié. Prix tissu: €4-7/m², vêtements: €12-18/pièce FOB. Livraison Lyon ou Marseille.', 'France', '🇫🇷', 'https://facebook.com/groups/modefrance/posts/bcd890', ARRAY['organic cotton', 'GOTS', 'textile', '有机棉'], '€50,000-€80,000', '500 kg', 'GOTS, OEKO-TEX', 'Marseille Port', 87),

('Reddit', 'Fitness_Brazil', 'https://i.pravatar.cc/150?img=15', 'Brazilian gym equipment importer needs treadmills and exercise bikes', 'São Paulo fitness chain expanding. Need 100 commercial treadmills and 150 exercise bikes from China. INMETRO certification.', 'Olá! Estamos expandindo nossa rede de academias em São Paulo e buscamos fabricante chinês de equipamentos fitness. Necessidades: 100 esteiras comerciais (motor 4HP+, velocidade até 22km/h) e 150 bicicletas ergométricas. Certificação INMETRO obrigatória para Brasil. Budget: esteiras USD 800-1200/unidade, bicicletas USD 250-400/unidade. Porto de Santos. Favor enviar catálogo e amostras.', 'Brazil', '🇧🇷', 'https://reddit.com/r/brasil/comments/efg123', ARRAY['fitness equipment', '健身器材', 'treadmill', 'INMETRO'], '$120,000-$180,000', '250 units', 'INMETRO', 'Santos Port', 86),

('LinkedIn', 'Smart_Home_Japan', 'https://i.pravatar.cc/150?img=16', 'Japanese smart home device distributor seeking zigbee hub OEM', 'Tokyo smart home company needs custom zigbee hub with PSE certification. 1000 units. 2.4GHz + sub-GHz support.', 'こんにちは。東京のスマートホーム会社です。中国のメーカーからZigbee対応スマートホームハブのOEM製造を探しています。仕様: PSE認証必須、Zigbee 3.0 + Wi-Fi 6対応、壁掛けデザイン、MOQ 1,000台、予算 ¥4,500-6,500/台 FOB。Tokyo Bigsight展示会で展示予定のためサンプル急募。', 'Japan', '🇯🇵', 'https://linkedin.com/posts/smarthome_jp', ARRAY['smart home', '智能家居', 'zigbee', 'PSE'], '¥4,500,000-¥6,500,000', '1,000 units', 'PSE, Zigbee 3.0', 'Tokyo Port', 91),

('Facebook', 'Industrial_Poland', 'https://i.pravatar.cc/150?img=17', 'Polish industrial tools importer needs angle grinders - CE certified', 'Warsaw tool distributor needs 1000 pcs angle grinders from China. 115mm and 125mm. CE certification mandatory.', 'Cześć! Jestem importerem narzędzi przemysłowych z Warszawy. Szukam dostawcy szlifierek kątowych z Chin: 115mm i 125mm, silnik 720W-900W, certyfikat CE obowiązkowy, EN 60745 norma. MOQ 500 szt. każdy rozmiar. Budżet: €18-25/szt. FOB Shanghai. Dostawa do Gdańska lub Gdyni. Wysyłam szczegółową specyfikację na życzenie.', 'Poland', '🇵🇱', 'https://facebook.com/groups/narzedzia_pl/posts/hij456', ARRAY['angle grinder', '角磨机', 'CE', 'power tools'], '€18,000-€25,000', '1,000 units', 'CE, EN 60745', 'Gdansk Port', 84),

('Reddit', 'Coffee_Italy', 'https://i.pravatar.cc/150?img=18', 'Italian coffee equipment company seeks espresso machine components', 'Milan-based company seeks Chinese supplier for espresso machine boilers and pump assemblies. NSF/CE certified.', 'Ciao! Siamo produttori di macchine espresso a Milano. Cerchiamo fornitore cinese per componenti: caldaie in acciaio inox AISI 316L (diametro 100-150mm), pompe volumetriche 15-20 bar. Certificazioni NSF (contatto alimenti) e CE obbligatorie. MOQ 500 caldaie, 1000 pompe. Budget caldaie: €15-25/pz, pompe: €8-15/pz. Qualità Swiss/German standard. Porto di Genova.', 'Italy', '🇮🇹', 'https://reddit.com/r/coffee/comments/klm789', ARRAY['espresso machine', '咖啡机', 'NSF', 'stainless steel'], '€15,500-$27,500', '1,500 units', 'NSF, CE', 'Genova Port', 83),

('LinkedIn', 'Pharma_India', 'https://i.pravatar.cc/150?img=19', 'Indian pharmaceutical company needs API from China - GMP certified factory', 'Mumbai pharma company seeking Chinese API supplier. Metformin HCl 500MT/year. US FDA approved factory preferred.', 'Namaste! We are a pharmaceutical company in Mumbai looking for Chinese manufacturer of Metformin Hydrochloride API. Requirements: GMP certified (WHO GMP preferred), US FDA approved factory a plus, purity 99.5%+, annual volume 500MT. We can arrange site audit. CIF Mumbai port pricing required. Long-term partnership preferred. Please send CoA, GMP certificate and DMF details.', 'India', '🇮🇳', 'https://linkedin.com/posts/pharma_india_api', ARRAY['API', 'pharmaceutical', '原料药', 'GMP', 'Metformin'], '$2,500,000+/year', '500 MT/year', 'GMP, US FDA', 'Mumbai Port', 95),

('Facebook', 'Footwear_Spain', 'https://i.pravatar.cc/150?img=20', 'Spanish footwear brand seeking athletic shoe OEM manufacturer', 'Madrid sports brand needs OEM sneaker manufacturer. 500 pairs/style, 3 styles. EU safety standards, no AZO dyes.', 'Hola! Somos una marca deportiva española buscando fabricante OEM en China para zapatillas atléticas. Necesidades: 3 estilos diferentes, 500 pares por estilo por pedido inicial, materiales: suela EVA+rubber, upper mesh/knit. Normativas UE: sin colorantes AZO, REACH compliance. Presupuesto: €15-25/par FOB Guangzhou. Muestra gratuita requerida antes del pedido. Puerto destino: Valencia.', 'Spain', '🇪🇸', 'https://facebook.com/groups/calzado_es/posts/nop012', ARRAY['sneakers', 'footwear', 'OEM', 'REACH', '运动鞋'], '€22,500-€37,500', '1,500 pairs', 'REACH, AZO-free', 'Valencia Port', 82),

('Reddit', 'Packaging_Netherlands', 'https://i.pravatar.cc/150?img=21', 'Dutch packaging company needs kraft paper bags - FSC certified', 'Rotterdam packaging distributor seeks 5 million kraft bags. FSC certified. Food grade. Multiple sizes.', 'Hello from Rotterdam! We are a packaging distributor supplying supermarkets and bakeries across Benelux. Urgent need for kraft paper bags: 5 million pieces total in 4 sizes (small/medium/large/XL), food-grade, FSC certified paper. No bleach, biodegradable. Budget €0.08-0.15/piece depending on size. Ship to Rotterdam port. EDI invoicing required for our ERP system. Monthly standing orders possible.', 'Netherlands', '🇳🇱', 'https://reddit.com/r/packaging/comments/qrs345', ARRAY['kraft paper bag', '牛皮纸袋', 'FSC', 'food grade'], '€400,000-€750,000', '5,000,000 pieces', 'FSC, food grade', 'Rotterdam Port', 88),

('LinkedIn', 'Electronics_Korea', 'https://i.pravatar.cc/150?img=22', 'Korean electronics company needs PCBA assembly service - IPC class 2', 'Seoul electronics firm seeking China PCBA partner. Monthly 10,000 boards. SMT, THT, IPC Class 2. NDA required.', '안녕하세요. 서울의 전자부품 회사에서 중국 PCBA 위탁 생산 파트너를 찾습니다. 사양: 월 10,000 PCS, SMT + THT 혼합, IPC Class 2 품질, AOI/X-ray 검사 포함, BGA 0402 부품 경험 필수. 월 단가 USD $8-15/board 목표. 비밀유지계약 필수. 깊이 파고든 협력 원합니다. 견적 및 공장 자격 서류 요청드립니다.', 'South Korea', '🇰🇷', 'https://linkedin.com/posts/pcba_korea', ARRAY['PCBA', 'SMT', 'PCB', 'IPC', '电路板'], '$960,000-$1,800,000/year', '10,000 boards/month', 'IPC Class 2, ISO 9001', 'Incheon Port', 93),

('Facebook', 'Agriculture_Nigeria', 'https://i.pravatar.cc/150?img=23', 'Nigerian agricultural equipment importer needs water pumps and irrigation', 'Lagos agri-business needs 500 diesel water pumps and drip irrigation systems. Budget $500K. Apapa port delivery.', 'Hello! We supply agricultural equipment to farmers across Nigeria. Looking for Chinese manufacturer/exporter: 1) Diesel water pumps 2-inch to 4-inch (500 units), flow rate 500-2000 L/min, 2) Drip irrigation systems for 1000 hectares, 3) Solar water pumps 50 units. Budget total USD 500,000. Prefer Nigerian NAFDAC compliant products. Shipping to Apapa Port Lagos. Letter of credit payment acceptable.', 'Nigeria', '🇳🇬', 'https://facebook.com/groups/agrilagos/posts/tuv678', ARRAY['water pump', 'irrigation', '水泵', '农业'], '$400,000-$600,000', 'Multiple items', 'NAFDAC', 'Apapa Port', 86),

('Reddit', 'Cosmetics_Russia', 'https://i.pravatar.cc/150?img=24', 'Russian cosmetics company needs OEM skincare line from China', 'Moscow beauty company seeks Chinese OEM for serum, moisturizer, sunscreen. EAC/GOST certified. 5000 units each.', 'Здравствуйте! Мы косметическая компания из Москвы. Ищем китайского OEM-производителя косметики: 1) Сыворотка с витамином C 30мл, 2) Дневной увлажняющий крем 50мл, 3) Солнцезащитный крем SPF 50+ 50мл. Требования: сертификация EAC (EAEU), ГОСТ Р, натуральные ингредиенты, белый лейбл. МОQ 5000 ед. каждого. Цена: $3-6/ед. ФОБ. Порт назначения: Владивосток или Новороссийск.', 'Russia', '🇷🇺', 'https://reddit.com/r/russia/comments/wxy901', ARRAY['cosmetics', 'OEM', '化妆品', 'EAC', 'skincare'], '$45,000-$90,000', '15,000 units', 'EAC, GOST', 'Vladivostok Port', 80),

('LinkedIn', 'Construction_UAE', 'https://i.pravatar.cc/150?img=25', 'UAE construction company needs scaffolding systems - CIDB certified', 'Dubai construction group needs 50,000 sqm scaffolding. CIDB/DEWA compliant. Jebel Ali port.', 'Hello from Dubai! Our construction group is working on multiple high-rise projects. Need Chinese scaffolding system supplier: frame scaffolding and ringlock scaffolding, total 50,000 sqm equivalent. CIDB certification, compliance with Dubai Municipality standards. Budget AED 25-35/sqm. Jebel Ali free zone delivery preferred. Need complete package with base plates, planks, safety nets. Contact for BOQ.', 'UAE', '🇦🇪', 'https://linkedin.com/posts/construction_uae', ARRAY['scaffolding', '脚手架', 'CIDB', 'construction'], 'AED $1,250,000-$1,750,000', '50,000 sqm', 'CIDB, DEWA', 'Jebel Ali Port', 91),

('Facebook', 'Toy_USA', 'https://i.pravatar.cc/150?img=26', 'US toy retailer seeking STEM educational toys manufacturer - ASTM certified', 'Chicago toy company needs 5000 STEM kits and robot toys. ASTM F963, CPSC compliance mandatory.', 'Hi! We are a toy company based in Chicago supplying to major US retailers including Target and Walmart. Seeking Chinese manufacturer for: 1) STEM building kit sets for ages 6-12 (2,000 sets), 2) Programmable robot toys (3,000 units). ASTM F963 and CPSC compliance mandatory, CPSIA lead-free, EN71 a plus. Budget: kits $8-15/set, robots $20-35/unit. LA port. Amazon FBA prep available.', 'United States', '🇺🇸', 'https://facebook.com/groups/toybuyers/posts/abc234', ARRAY['toys', 'STEM', 'ASTM', '玩具', 'educational'], '$110,000-$150,000', '5,000 units', 'ASTM F963, CPSC', 'Los Angeles Port', 89),

('Reddit', 'Bicycle_Netherlands', 'https://i.pravatar.cc/150?img=27', 'Dutch bicycle company needs e-bike components - EN 15194 certified', 'Amsterdam e-bike manufacturer seeking Chinese battery packs and motors. 1000 sets. EN 15194 mandatory.', 'Hello from Amsterdam! We assemble e-bikes for Dutch and Belgian markets. Sourcing Chinese e-bike components: 1) 36V 15Ah lithium battery packs with BMS (1,000 units), 2) 250W brushless rear hub motors (1,000 units). EN 15194 certification mandatory (EU e-bike standard), UN 38.3 for batteries. Budget: batteries €80-110/unit, motors €35-55/unit. Rotterdam port. Can discuss long-term supply agreement.', 'Netherlands', '🇳🇱', 'https://reddit.com/r/cycling/comments/cde567', ARRAY['e-bike', '电动自行车', 'battery', 'EN 15194'], '€115,000-€165,000', '1,000 sets', 'EN 15194, UN 38.3', 'Rotterdam Port', 90),

('LinkedIn', 'Mining_Chile', 'https://i.pravatar.cc/150?img=28', 'Chilean mining company seeks drilling equipment and rock crushers', 'Santiago mining supplier needs jaw crushers and drill bits from China. COCHILCO compliant. 10 units jaw crusher.', 'Hola, somos proveedores de equipos mineros en Santiago de Chile. Buscamos fabricante chino para: 10 trituradoras de mandíbula (capacidad 50-200 tph), 500 brocas de perforación rotativa (diámetros 4-12 pulgadas). Requisitos: cumplimiento normativas COCHILCO, certificación ISO 9001, materiales resistentes a abrasión. Presupuesto: USD 150,000-200,000 por trituradora, $50-200/broca. Puerto de Antofagasta.', 'Chile', '🇨🇱', 'https://linkedin.com/posts/mining_chile_equip', ARRAY['mining equipment', '矿山设备', 'jaw crusher', 'drilling'], '$1,750,000-$2,250,000', '10 crushers', 'ISO 9001, COCHILCO', 'Antofagasta Port', 85),

('Facebook', 'HVAC_USA', 'https://i.pravatar.cc/150?img=29', 'American HVAC contractor seeks mini-split AC systems wholesale - ETL listed', 'Florida HVAC company needs 200 mini-split AC systems (1.5-3 ton). ETL and ENERGY STAR certified.', 'Hey y''all! We are a large HVAC contractor in Florida. Looking to buy 200 mini-split systems direct from Chinese factory: single-zone and multi-zone, 18000-36000 BTU range. ETL listed mandatory, ENERGY STAR certified preferred, EER 16+. Budget $400-650/unit. Miami port or direct truck from west coast ports. Need factory warranty support and technical documentation. Good margins for recurring business.', 'United States', '🇺🇸', 'https://facebook.com/groups/hvac_pros/posts/fgh890', ARRAY['mini-split', 'AC', 'HVAC', 'ETL', 'ENERGY STAR'], '$80,000-$130,000', '200 units', 'ETL, ENERGY STAR', 'Miami Port', 88),

('Reddit', 'Pet_UK', 'https://i.pravatar.cc/150?img=30', 'UK pet food brand seeking OEM dry dog food manufacturer - FEDIAF compliant', 'London pet brand needs OEM manufacturer for premium dry dog food. FEDIAF guidelines, UK food standards.', 'Hello from London! We are launching a premium pet food brand in UK. Need Chinese OEM manufacturer for dry kibble dog food: grain-free recipe with chicken/salmon protein, 20kg bags, MOQ 10,000 kg per recipe. FEDIAF guidelines compliance, UK food standards authority requirements. BRC/IFS certification preferred. Budget £0.80-1.20/kg ex-works. Custom packaging with our brand. Vet nutritionist formulated recipes.', 'United Kingdom', '🇬🇧', 'https://reddit.com/r/dogs/comments/ijk123', ARRAY['pet food', 'OEM', '宠物食品', 'FEDIAF'], '£80,000-£120,000/batch', '10,000 kg', 'FEDIAF, BRC', 'Felixstowe Port', 82),

-- ===== 中文线索 =====
('Facebook', '采购经理_王华', 'https://i.pravatar.cc/150?img=31', '急！需要大量不锈钢水龙头，工程项目采购', '北京房地产开发商寻找不锈钢卫浴五金供应商，30000只水龙头，需要NSF认证，1个月内交货。', '您好，我是北京某大型房地产开发公司采购经理。我们正在开发3个住宅小区，急需采购30000只不锈钢厨卫水龙头（冷热混合型）。要求：304不锈钢材质，NSF61认证，滴漏率<0.03L/h，压力0.05-0.8MPa适用。预算：35-55元/只。天津港接收货物，一个月内必须交货。有意向请立即联系，我们可以提前付款30%。', 'China', '🇨🇳', 'https://facebook.com/groups/caigou_cn/posts/lmn456', ARRAY['不锈钢水龙头', 'faucet', 'NSF', '卫浴'], '¥1,050,000-¥1,650,000', '30,000只', 'NSF 61', '天津港', 92),

('Reddit', 'GlobalImport_Zhang', 'https://i.pravatar.cc/150?img=32', '外贸大单：寻找竹制家居产品工厂，出口欧洲', '义乌贸易公司为欧洲客户采购，竹砧板/竹餐具/竹收纳盒，10万件起，FSC认证，欧盟食品接触标准。', '我是义乌外贸公司，为多个欧洲零售客户长期采购竹制家居产品。当前需求：1.竹砧板（3种规格）5万件，2.竹餐具套装1万套，3.竹收纳盒（5种规格）4万件。要求：FSC认证，符合欧盟食品接触材料法规EC 1935/2004，无甲醛胶水。价格：砧板5-12元/件，餐具套装18-35元/套，收纳盒8-20元/件。宁波港发货，月结90天。', 'China', '🇨🇳', 'https://reddit.com/r/china/comments/opq789', ARRAY['竹制品', 'bamboo', 'FSC', '家居'], '¥2,000,000+', '100,000件', 'FSC, EC 1935/2004', '宁波港', 87),

('LinkedIn', '外贸李总', 'https://i.pravatar.cc/150?img=33', '阿联酋连锁超市采购中国方便食品，寻找OEM代工厂', '迪拜华人超市连锁为阿联酋本地化品牌采购方便面、自热食品，清真认证必须，50万包起', '你好！我代理迪拜一家华人超市集团，正在为其阿联酋本地品牌寻找中国食品OEM代工厂。需求：1.方便面（鸡汤、牛肉两种口味）50万包，2.自热米饭20万份，3.坚果零食礼盒5万盒。硬性要求：清真认证（ESMA或MUI），HACCP体系，中英阿三语包装，保质期18个月+。价格：方便面1.5-2.5元/包，自热饭8-15元/份。杰贝阿里港到货。', 'UAE', '🇦🇪', 'https://linkedin.com/posts/food_uae_oem', ARRAY['方便食品', 'halal', 'OEM', '清真', '食品出口'], '¥1,500,000-¥2,500,000', '750,000件', '清真认证, HACCP', '杰贝阿里港', 89),

-- ===== 阿拉伯语线索 =====
('Facebook', 'Abdul_Riyadh', 'https://i.pravatar.cc/150?img=34', 'مطلوب موردين لأجهزة الطاقة الشمسية - شهادة SASO', 'شركة سعودية تبحث عن مورد صيني لألواح الطاقة الشمسية وعاكسات الطاقة بشهادة SASO للسوق السعودي', 'السلام عليكم، نحن شركة متخصصة في الطاقة المتجددة في الرياض. نبحث عن مورد صيني موثوق لـ: 500 لوح طاقة شمسية 450 وات، 100 عاكس طاقة 5 كيلوواط. المتطلبات: شهادة SASO إلزامية، IEC 61215 للألواح، ضمان 25 سنة على الأداء الخطي. الميزانية: ألواح 90-120 دولار/قطعة، عاكسات 300-450 دولار/قطعة. التسليم لميناء جدة. دفع LC مقبول.', 'Saudi Arabia', '🇸🇦', 'https://facebook.com/groups/energy_sa/posts/rst012', ARRAY['solar panel', 'SASO', '太阳能', 'Saudi Arabia'], '$90,000-$105,000', '500 panels', 'SASO, IEC 61215', 'Jeddah Port', 90),

('LinkedIn', 'Omar_Cairo', 'https://i.pravatar.cc/150?img=35', 'مصنع مصري يبحث عن آلات صناعية من الصين - شهادة CE', 'مصنع نسيج في القاهرة يبحث عن آلات نسيج صينية بمحركات سيرفو. 10 آلات. شهادة CE والضمان الشامل.', 'مرحبًا، أنا مدير المشتريات في مصنع نسيج كبير بالقاهرة. نحن نبحث عن مورد صيني لآلات النسيج الأوتوماتيكية: 10 آلات حياكة دائرية 30 بوصة بمحركات سيرفو ولوحات تحكم PLC. الاشتراطات: شهادة CE، ضمان سنتين شامل، خدمة ما بعد البيع في مصر، وثائق عربية/إنجليزية. الميزانية: 15,000-25,000 دولار/آلة FOB شنغهاي. ميناء الإسكندرية.', 'Egypt', '🇪🇬', 'https://linkedin.com/posts/textile_egypt', ARRAY['textile machinery', '纺织机械', 'CE', 'Egypt'], '$150,000-$250,000', '10 machines', 'CE, ISO 9001', 'Alexandria Port', 85),

-- ===== 西班牙语线索 =====
('Reddit', 'ImportadorCol', 'https://i.pravatar.cc/150?img=36', 'Colombia: buscamos proveedor de electrodomésticos chinos - RETIE certificación', 'Bogotá importadora necesita 1000 ventiladores de techo y 500 aires acondicionados. Certificación RETIE Colombia obligatoria.', 'Hola desde Bogotá! Somos importadora de electrodomésticos para Colombia y Ecuador. Necesitamos: 1000 ventiladores de techo con iluminación LED (48-52 pulgadas), 500 aires acondicionados tipo split 9000-18000 BTU. Certificación RETIE obligatoria para Colombia, INEN para Ecuador. Eficiencia energética clase A. Presupuesto: ventiladores USD 45-75/unidad, aires: USD 200-350/unidad. Puerto de Barranquilla. Pago 30% adelanto, 70% contra documentos.', 'Colombia', '🇨🇴', 'https://reddit.com/r/colombia/comments/uvw345', ARRAY['electrodomésticos', '家电', 'RETIE', 'Colombia'], '$170,000-$250,000', '1,500 units', 'RETIE, INEN', 'Barranquilla Port', 83),

-- ===== 德语线索 =====
('Facebook', 'Bauer_Austria', 'https://i.pravatar.cc/150?img=37', 'Österreichischer Händler sucht Hersteller für Gartengeräte - GS-Zeichen', 'Wien Gartengeräte-Händler sucht chinesischen Lieferanten für Laubbläser und Heckenscheren. GS-Zeichen und CE-Zertifizierung erforderlich.', 'Hallo aus Wien! Wir sind ein österreichischer Gartengeräte-Fachhändler. Suchen chinesischen Hersteller für: 500 Laubbläser (elektrisch und Akku, 18V), 300 Heckenscheren (60cm Schnittlänge). GS-Zeichen zwingend erforderlich, CE-Zertifizierung, EN 50144. Budget: Laubbläser €40-65/Stück, Heckenscheren €55-80/Stück FOB. Lieferung Wien über Hamburger Hafen. Österreichische Produktkonformitätserklärung benötigt.', 'Austria', '🇦🇹', 'https://facebook.com/groups/gartenoesterreich/posts/xyz678', ARRAY['garden tools', '园林工具', 'GS', 'CE', 'Austria'], '€39,500-€56,500', '800 units', 'GS, CE, EN 50144', 'Hamburg Port', 81),

-- ===== 补充更多线索 =====
('Reddit', 'BuildMat_Turkey', 'https://i.pravatar.cc/150?img=38', 'Turkish construction materials importer needs ceramic tiles', 'Istanbul importer needs 50,000 sqm ceramic floor tiles. TS EN ISO 10545 standard. Mersin port.', 'Hello from Istanbul! We distribute construction materials to contractors across Turkey. Need Chinese ceramic floor tiles: 50,000 sqm total, sizes 60x60cm and 80x80cm, anti-slip R10 rating, TS EN ISO 10545 compliance. Budget $8-14/sqm FOB. Prefer manufacturers in Foshan or Guangdong. Ship to Mersin port. We import containers regularly, interested in long-term relationship.', 'Turkey', '🇹🇷', 'https://reddit.com/r/turkey/comments/abc123t', ARRAY['ceramic tiles', '瓷砖', 'TS EN', 'construction'], '$400,000-$700,000', '50,000 sqm', 'TS EN ISO 10545', 'Mersin Port', 86),

('LinkedIn', 'Agro_Argentina', 'https://i.pravatar.cc/150?img=39', 'Argentine agro chemical company seeks herbicide raw materials', 'Buenos Aires agro company needs glyphosate and 2,4-D technical grade from China. SENASA registration support needed.', 'Hola! Somos fabricantes de agroquímicos en Buenos Aires. Buscamos proveedores chinos de materias primas: 1) Glifosato grado técnico 95% (200 toneladas/año), 2) 2,4-D ácido técnico 98% (100 toneladas/año). Requisitos: GMP, registro ante SENASA Argentina, ISO 9001, análisis COA por lote. CIF Buenos Aires. Pago mediante carta de crédito. Alianza de largo plazo para empresa seria.', 'Argentina', '🇦🇷', 'https://linkedin.com/posts/agrochem_arg', ARRAY['herbicide', 'glyphosate', '草甘膦', 'agrochem'], '$1,500,000+/year', '300 tons/year', 'GMP, ISO 9001', 'Buenos Aires Port', 88),

('Facebook', 'PowerTool_Sweden', 'https://i.pravatar.cc/150?img=40', 'Swedish hardware chain sourcing cordless tool sets from China', 'Stockholm hardware retailer needs 2000 cordless drill/driver sets. CE, IEC 60745. Brushless motor required.', 'Hej from Stockholm! We are a hardware chain with 45 stores in Sweden and Norway. Looking for Chinese manufacturer for cordless drill sets: 20V brushless motor, 2-battery kit (4Ah), CE certification, IEC 60745, rubber grip ergonomic design. MOQ 2,000 sets. Budget SEK 350-500/set. Ship to Gothenburg port. We provide our own branding (white label acceptable). Good margins for exclusive distribution rights.', 'Sweden', '🇸🇪', 'https://facebook.com/groups/nordic_hardware/posts/def890', ARRAY['cordless drill', '无刷电钻', 'CE', 'IEC 60745'], 'SEK $700,000-$1,000,000', '2,000 sets', 'CE, IEC 60745', 'Gothenburg Port', 87),

('Reddit', 'Pharma_South_Africa', 'https://i.pravatar.cc/150?img=41', 'South African pharmacy chain needs OTC medicines from China', 'Johannesburg pharmacy group seeks paracetamol tablets and ibuprofen. SAHPRA registered supplier. 5 million tablets.', 'Hello from Johannesburg! Our pharmacy chain operates 120 stores across South Africa. Seeking Chinese manufacturer for OTC medicines: 1) Paracetamol 500mg tablets, 5 million tablets, 2) Ibuprofen 200mg and 400mg tablets, 3 million tablets total. SAHPRA registration for South Africa mandatory, GMP WHO certification. Budget: paracetamol ZAR 0.08-0.15/tablet, ibuprofen ZAR 0.12-0.20/tablet. Durban port.', 'South Africa', '🇿🇦', 'https://reddit.com/r/southafrica/comments/ghi456', ARRAY['pharmaceuticals', 'OTC', 'paracetamol', 'SAHPRA', '药品'], 'ZAR $1,040,000-$1,800,000', '8,000,000 tablets', 'SAHPRA, GMP', 'Durban Port', 91),

('LinkedIn', 'Telecom_Kenya', 'https://i.pravatar.cc/150?img=42', 'Kenyan telecom company needs fiber optic cables and network equipment', 'Nairobi telecom needs 5000km fiber optic cable and 200 OLT units. CA certified. EAC compliant.', 'Hello from Nairobi! We are a telecommunications infrastructure company in Kenya. Major project requiring: 1) Single-mode fiber optic cable 5,000km (G.652D ITU-T standard), 2) GPON OLT units 200 units (32PON ports min). IK Certification Authority compliance, EAC standards, KEBS approval for Kenya market. Budget: fiber $0.08-0.15/meter, OLT $3,000-5,000/unit. Mombasa port delivery. Government project, L/C payment.', 'Kenya', '🇰🇪', 'https://linkedin.com/posts/telecom_kenya', ARRAY['fiber optic', '光纤', 'GPON', 'telecom'], '$1,500,000-$2,500,000', 'Large project', 'ITU-T, KEBS', 'Mombasa Port', 89),

('Facebook', 'Auto_Parts_Mexico', 'https://i.pravatar.cc/150?img=43', 'Mexican auto parts distributor needs brake pads and filters wholesale', 'Monterrey auto parts company seeks Chinese brake pads (IATF 16949) and oil filters for Toyota/Honda fitments.', 'Hola! Somos distribuidores de refacciones automotrices en Monterrey, México. Buscamos proveedor chino de: 1) Pastillas de freno (compatibles Toyota Corolla, Honda Civic, Nissan Sentra - top 10 modelos México), 50,000 juegos, 2) Filtros de aceite 80,000 piezas. Certificación IATF 16949 requerida, NOM correspondiente. Precio: pastillas USD 3-6/juego, filtros USD 1.5-3/pieza. Puerto Lázaro Cárdenas. Compras mensuales recurrentes para distribuidor serio.', 'Mexico', '🇲🇽', 'https://facebook.com/groups/autopartes_mx/posts/jkl234', ARRAY['brake pads', 'auto parts', 'IATF 16949', '汽车配件'], '$350,000-$630,000', '130,000 units', 'IATF 16949, NOM', 'Lazaro Cardenas Port', 88),

('Reddit', 'Organic_Denmark', 'https://i.pravatar.cc/150?img=44', 'Danish organic food company needs Chinese herbal extracts - EU Organic', 'Copenhagen health brand seeks astragalus, ginseng, goji berry extracts. EU Organic cert. EFSA novel food compliant.', 'Hello from Copenhagen! We make premium health supplements sold across Scandinavia. Sourcing Chinese botanical extracts: 1) Astragalus root extract 40% polysaccharides (200kg/year), 2) Ginseng extract 20% ginsenosides (100kg/year), 3) Goji berry extract 40% polysaccharides (150kg/year). EU Organic certification mandatory, EFSA novel food assessment required, heavy metals <10ppm. Budget €80-150/kg. Frankfurt or Copenhagen delivery. COA and stability data required.', 'Denmark', '🇩🇰', 'https://reddit.com/r/denmark/comments/mno567', ARRAY['herbal extract', '植物提取物', 'EU Organic', 'ginseng'], '€37,000-€67,500', '450 kg/year', 'EU Organic, EFSA', 'Copenhagen Port', 85),

('LinkedIn', 'Power_India', 'https://i.pravatar.cc/150?img=45', 'Indian power sector company needs transformer components from China', 'Mumbai electrical company seeks transformer cores and winding copper for 100 units 11kV/415V transformers.', 'Namaste! We manufacture distribution transformers in Mumbai for Indian power utilities. Sourcing Chinese components: 1) Silicon steel lamination cores for 100-500 kVA transformers (50 metric tons), 2) Enameled copper winding wire (Grade 2 IEC 60317, 20 metric tons). BIS certification where applicable, IS/IEC standards. Budget: cores INR 120-150/kg, copper wire INR 650-750/kg. JNPT Mumbai port. Regular monthly orders for established supplier.', 'India', '🇮🇳', 'https://linkedin.com/posts/power_india_transformer', ARRAY['transformer', '变压器', 'silicon steel', 'BIS'], 'INR $9,000,000-$12,000,000', '70 metric tons', 'BIS, IEC 60317', 'JNPT Mumbai', 87),

('Facebook', 'Gaming_Poland', 'https://i.pravatar.cc/150?img=46', 'Polish gaming accessories retailer seeking mechanical keyboard OEM', 'Warsaw gaming store needs 5000 mechanical keyboards with RGB. CE, RoHS. Custom layouts available.', 'Cześć! Prowadzimy sklep z akcesoriami gamingowymi w Polsce. Szukamy chińskiego producenta OEM dla klawiatur mechanicznych: 5000 szt., przełączniki taktyczne (blue/red/brown), RGB podświetlenie pełne, układ TKL lub 75%, materiał aluminium lub ABS premium. CE, RoHS obligatoryjne. Budżet: €25-45/szt. Nasz własny branding. Wysyłka do Gdańska. Prezentacja prototypu wymagana przed zamówieniem.', 'Poland', '🇵🇱', 'https://facebook.com/groups/gaming_pl/posts/pqr890', ARRAY['mechanical keyboard', '机械键盘', 'OEM', 'RGB', 'gaming'], '€125,000-€225,000', '5,000 units', 'CE, RoHS', 'Gdansk Port', 82),

('Reddit', 'Cheese_New_Zealand', 'https://i.pravatar.cc/150?img=47', 'New Zealand dairy company seeking Chinese packaging machinery', 'Auckland dairy seeks vacuum packaging machines and flow wrappers. AS/NZS compliant. Food-grade materials.', 'Hi from Auckland! We are a dairy producer in New Zealand looking for Chinese food packaging machinery: 1) Thermoform vacuum packaging machine (output 40 packs/min), 2) Flow wrapper for cheese blocks (50 packs/min). AS/NZS compliance, food-grade 304SS contact parts, HACCP design principles. Budget: vacuum packer NZD 80,000-120,000, flow wrapper NZD 60,000-90,000. Freight to Auckland port. 12-month warranty with local service network required.', 'New Zealand', '🇳🇿', 'https://reddit.com/r/newzealand/comments/stu123', ARRAY['packaging machine', '包装机械', 'food processing', 'AS/NZS'], 'NZD $140,000-$210,000', '2 machines', 'AS/NZS, HACCP', 'Auckland Port', 84),

('LinkedIn', 'Steel_Vietnam', 'https://i.pravatar.cc/150?img=48', 'Vietnamese steel company needs CNC machining services from China', 'Hanoi manufacturing seeks Chinese CNC partner for steel components. ISO 9001. 500 tons/year.', 'Xin chào! Chúng tôi là công ty gia công cơ khí tại Hà Nội, Việt Nam. Tìm kiếm đối tác gia công CNC từ Trung Quốc: phôi thép carbon và thép không gỉ, chi tiết máy công nghiệp, dung sai ±0.05mm, sản lượng 500 tấn/năm. Yêu cầu: ISO 9001:2015, báo cáo CMM, chứng chỉ vật liệu. Giá mục tiêu: $2-5/kg gia công. Giao hàng cảng Hải Phòng. Hợp đồng dài hạn ưu tiên.', 'Vietnam', '🇻🇳', 'https://linkedin.com/posts/cnc_vietnam', ARRAY['CNC machining', 'CNC加工', 'steel', 'ISO 9001'], '$1,000,000-$2,500,000/year', '500 tons/year', 'ISO 9001', 'Haiphong Port', 86),

('Facebook', 'Jewelry_Italy', 'https://i.pravatar.cc/150?img=49', 'Italian jewelry brand seeks sterling silver components OEM', 'Milan jewelry house needs Chinese OEM for 925 sterling silver findings and chains. Nickel-free EU Directive.', 'Ciao da Milano! Siamo una casa di gioielli che cerca produttore OEM cinese per componenti in argento sterling 925: chiusure, ganci, catenine (50,000 pezzi mix), anelli base per ridimensionamento (20,000 pezzi). Requisiti: nichel-free secondo Direttiva EU 2004/96/CE, marcatura 925, REACH compliance. Budget: €0.50-3.00/pezzo dipende dal peso. Imballaggio individuale richiesto. Porto di Genova. Campioni gratuiti prima dell''ordine.', 'Italy', '🇮🇹', 'https://facebook.com/groups/gioielli_it/posts/uvw456', ARRAY['silver jewelry', '925银', 'OEM', 'nickel-free', '珠宝'], '€45,000-€80,000', '70,000 pieces', 'EU Nickel Directive, REACH', 'Genova Port', 80),

('Reddit', 'Chemical_Belgium', 'https://i.pravatar.cc/150?img=50', 'Belgian chemical company needs solvents and intermediates from China', 'Antwerp chemical distributor seeks ethyl acetate and IPA. REACH registered. ADR compliant packaging.', 'Hello from Antwerp! We are a chemical distributor supplying Belgian and Dutch manufacturers. Need Chinese chemical supplier for: 1) Ethyl Acetate industrial grade 99.5% (500MT/month), 2) Isopropyl Alcohol 99.9% (200MT/month). REACH pre-registration required, ECHA SVHC free, ADR compliant packaging for EU transport. CIF Antwerp pricing required. We have own tank trucks for port collection. LC payment. Long-term framework contract preferred.', 'Belgium', '🇧🇪', 'https://reddit.com/r/belgium/comments/xyz789', ARRAY['solvents', 'chemicals', 'REACH', 'ethyl acetate', '化工'], '$2,400,000+/year', '700 MT/month', 'REACH, ADR', 'Antwerp Port', 89),

('LinkedIn', 'Textile_Bangladesh', 'https://i.pravatar.cc/150?img=51', 'Bangladeshi garment factory needs polyester fabric from China', 'Dhaka apparel manufacturer needs 1000 tons/year polyester fabric. OEKO-TEX. Competitive pricing critical.', 'Hello! We operate a garment factory in Dhaka, Bangladesh with 2,000 workers making sportswear for European brands. Seeking Chinese polyester fabric supplier: 1) Recycled polyester interlock 150gsm (600 tons/year), 2) Polyester mesh fabric 120gsm (400 tons/year). OEKO-TEX STANDARD 100 mandatory, GRS (Global Recycled Standard) for recycled materials. Price target: USD 1.80-2.80/meter. Chittagong port delivery. Monthly orders. Payment LC 90 days.', 'Bangladesh', '🇧🇩', 'https://linkedin.com/posts/textile_bd', ARRAY['polyester fabric', '涤纶面料', 'OEKO-TEX', 'GRS'], '$1,800,000-$2,800,000/year', '1,000 tons/year', 'OEKO-TEX, GRS', 'Chittagong Port', 87),

('Facebook', 'Solar_Thailand', 'https://i.pravatar.cc/150?img=52', 'Thai solar installer needs panels and inverters - TISI standard', 'Bangkok solar company needs 2MW solar project equipment. TISI certification, IEC standards. Good Credit.', 'Sawadee ka! We are solar installation company in Bangkok. Procuring equipment for multiple 2MW rooftop projects. Need: Tier-1 solar panels 550W+ (3,600 pieces), string inverters 100kW (20 units). TISI certification mandatory for Thailand market, IEC 61215 for panels, IEC 62109 for inverters. Budget: panels $0.22-0.28/W, inverters $0.05-0.08/W. Laem Chabang port delivery. Bank guarantee available. Decision within 30 days.', 'Thailand', '🇹🇭', 'https://facebook.com/groups/solar_th/posts/abc123s', ARRAY['solar panel', 'inverter', 'TISI', '光伏', 'Thailand'], '$1,100,000-$1,400,000', '3,620 units', 'TISI, IEC 61215', 'Laem Chabang Port', 93),

('Reddit', 'Rubber_Malaysia', 'https://i.pravatar.cc/150?img=53', 'Malaysian rubber product manufacturer needs silicone raw materials', 'Kuala Lumpur rubber factory seeks silicone rubber compound from China. Food-grade and industrial grade.', 'Hello from KL! We manufacture silicone products for automotive and food industry in Malaysia. Sourcing silicone rubber compounds from China: 1) Food-grade silicone 50 Shore A (10 tons/month) - FDA 21 CFR, SGS tested, 2) High-temperature silicone 70 Shore A for automotive (5 tons/month) - heat resistant 200°C+. REACH compliance, SVHC-free. Price target: $4-7/kg FOB Guangzhou. Port Klang delivery. Monthly standing order available for right supplier.', 'Malaysia', '🇲🇾', 'https://reddit.com/r/malaysia/comments/def456r', ARRAY['silicone', 'rubber', 'FDA', 'food grade', '硅橡胶'], '$720,000-$1,260,000/year', '180 tons/year', 'FDA 21 CFR, REACH', 'Port Klang', 85),

('LinkedIn', 'Glass_Egypt', 'https://i.pravatar.cc/150?img=54', 'Egyptian glass company needs float glass and tempered glass from China', 'Alexandria glass distributor needs 500 tons float glass and 50,000 sqm tempered glass. EGS standard.', 'مرحبًا، نحن موزعو الزجاج في الإسكندرية بمصر. نحتاج من الصين: 1) زجاج عائم 4مم و6مم بسماكة، 500 طن، 2) زجاج مقسّى 8مم و10مم للمباني، 50,000 متر مربع. معيار EGS/EN 572 للزجاج العائم، EN 12150 للمقسّى. الميزانية: زجاج عائم 350-500 دولار/طن، مقسّى 8-15 دولار/م². ميناء الإسكندرية. خطاب اعتماد مقبول. نسعى لعلاقة طويلة الأمد.', 'Egypt', '🇪🇬', 'https://linkedin.com/posts/glass_egypt', ARRAY['float glass', 'tempered glass', '钢化玻璃', 'Egypt'], '$425,000-$650,000', '500 tons + 50,000 sqm', 'EN 572, EN 12150', 'Alexandria Port', 84),

('Facebook', 'Lighting_UAE', 'https://i.pravatar.cc/150?img=55', 'UAE hotel chain needs architectural LED lighting - DEWA approved', 'Dubai hotel developer needs 50,000 pcs LED downlights and strip lights. DEWA approved. IES LM-80.', 'Hello! We are developing 3 luxury hotels in Dubai and Abu Dhabi. Need architectural LED lighting from Chinese manufacturer: 10,000 pcs LED downlights (10W, CRI90+, 3000K), 40,000m LED strip lights (24V, CRI95+, tuneable white). DEWA approved products mandatory, IES LM-80 report, TRIAC dimmable. Budget: downlights AED 45-75/pc, strips AED 25-40/m. Jebel Ali port. Interior designer approval required on samples.', 'UAE', '🇦🇪', 'https://facebook.com/groups/uae_construction/posts/ghi789l', ARRAY['LED lighting', 'LED灯', 'DEWA', 'hotel', 'architectural'], 'AED $2,225,000-$3,250,000', '10,000 pc + 40,000m', 'DEWA, IES LM-80', 'Jebel Ali Port', 92),

('Reddit', 'Pump_Brazil', 'https://i.pravatar.cc/150?img=56', 'Brazilian water treatment company needs centrifugal pumps from China', 'São Paulo water utility needs 100 centrifugal pumps for water treatment plant upgrade. INMETRO, ISO 9001.', 'Olá! Somos empresa de tratamento de água em São Paulo. Precisamos de bombas centrífugas chinesas para reforma de estação de tratamento: 100 bombas centrífugas (vazão 500-2000 m³/h, altura manométrica 20-80m), materiais bronze e aço inox 316L partes em contato com água. Certificação INMETRO, ABNT NBR ISO 5199 aplicável, ISO 9001. Orçamento: USD 3,000-8,000/unidade FOB. Porto de Santos. Licitação pública, documentação técnica completa necessária.', 'Brazil', '🇧🇷', 'https://reddit.com/r/brasil/comments/jkl012p', ARRAY['centrifugal pump', '离心泵', 'water treatment', 'INMETRO'], '$300,000-$800,000', '100 units', 'INMETRO, ISO 5199', 'Santos Port', 86),

('LinkedIn', 'Food_Indonesia', 'https://i.pravatar.cc/150?img=57', 'Indonesian food company needs flavor additives from China - BPOM registered', 'Jakarta food manufacturer seeks MSG and citric acid from China. BPOM Indonesia registration required.', 'Halo dari Jakarta! Kami perusahaan makanan di Indonesia membutuhkan bahan tambahan pangan dari China: 1) Monosodium Glutamate (MSG) food grade 200 ton/tahun, 2) Citric acid anhydrous 100 ton/tahun, 3) Xanthan gum 50 ton/tahun. Wajib: registrasi BPOM Indonesia, sertifikat halal MUI, HACCP, Codex Alimentarius. Target harga: MSG USD 800-1,100/ton CIF, citric acid USD 900-1,200/ton CIF. Pelabuhan Tanjung Priok Jakarta. LC 60 hari.', 'Indonesia', '🇮🇩', 'https://linkedin.com/posts/food_indonesia', ARRAY['food additives', '食品添加剂', 'MSG', 'BPOM', 'halal'], '$570,000-$800,000/year', '350 tons/year', 'BPOM, MUI Halal', 'Tanjung Priok Port', 88),

('Facebook', 'Mining_Australia', 'https://i.pravatar.cc/150?img=58', 'Australian mining supplier needs conveyor belts from China', 'Perth mining company needs 5000m heavy-duty conveyor belts for iron ore operations. AS/NZS 1333.', 'G''day! We supply equipment to Pilbara iron ore mines in Western Australia. Need Chinese manufacturer for mining conveyor belts: 5,000m total, ST2000 steel cord and EP 1500/5 fabric, widths 1000mm and 1200mm, heat resistant and anti-static grades. AS/NZS 1333 compliance, MSHA approved. Budget AUD $180-280/m. Fremantle port. Fire resistance test certificates required. Urgent as mine expansion ongoing.', 'Australia', '🇦🇺', 'https://facebook.com/groups/mining_au/posts/mno345c', ARRAY['conveyor belt', '传送带', 'mining', 'AS/NZS', 'iron ore'], 'AUD $900,000-$1,400,000', '5,000m', 'AS/NZS 1333, MSHA', 'Fremantle Port', 90),

('Reddit', 'Healthcare_Canada', 'https://i.pravatar.cc/150?img=59', 'Canadian hospital network needs disposable medical supplies from China', 'Toronto hospital group needs surgical gloves, masks and syringes. Health Canada licensed supplier only.', 'Hello from Toronto! We manage medical supplies for 12 hospitals in Ontario. Annual tender for disposable medical supplies from Chinese manufacturer: 1) Nitrile examination gloves, 5 million pieces, 2) Level 2 surgical masks, 2 million pieces, 3) 3mL/5mL syringes with needles, 3 million pieces. Health Canada device license mandatory, ISO 13485, FDA 510K for export evidence preferred. Budget: gloves CAD 0.12-0.18/pc, masks 0.15-0.25/pc, syringes 0.08-0.15/pc. Toronto delivery by air or sea.', 'Canada', '🇨🇦', 'https://reddit.com/r/canada/comments/pqr678h', ARRAY['medical supplies', '医疗耗材', 'Health Canada', 'ISO 13485'], 'CAD $1,350,000-$2,200,000', '10,000,000 pieces', 'Health Canada, ISO 13485', 'Toronto Port', 94),

('LinkedIn', 'Renewable_Spain', 'https://i.pravatar.cc/150?img=60', 'Spanish wind energy company seeks nacelle components from China', 'Madrid wind energy developer needs hub bearings and gearbox components for 50MW wind farm.', 'Hola desde Madrid! Desarrollamos parques eólicos en España y Marruecos. Necesitamos componentes para 25 aerogeneradores de 2MW: cojinetes de buje principales (Ø1200-1500mm, acero de aleación especial), componentes de multiplicadora (engranajes cónicos y helicoidales, materiales 18CrNiMo7-6). ISO 281, IEC 61400-4 para componentes eólicos. Presupuesto: 50,000-80,000 USD/set completo. ITAR-free. Documentación de trazabilidad material completa. Puerto de Bilbao.', 'Spain', '🇪🇸', 'https://linkedin.com/posts/wind_energy_es', ARRAY['wind energy', '风能', 'bearings', 'gearbox', 'renewable'], '$1,250,000-$2,000,000', '25 sets', 'IEC 61400, ISO 281', 'Bilbao Port', 87);

-- ============================================================
-- 6. 管理员用户（如已有用户，手动插入角色）
-- ============================================================
-- 注意：以下仅为示例，实际需要用 auth.users 中的真实 UUID
-- 管理员邮箱 oraora2026@163.com 注册后，触发器会自动赋予 admin 角色

-- ============================================================
-- 7. 验证数据
-- ============================================================
SELECT COUNT(*) as total_clues FROM radar_clues;
SELECT country, COUNT(*) as count FROM radar_clues GROUP BY country ORDER BY count DESC;
SELECT keyword_tags, title FROM radar_clues WHERE '割草机' = ANY(keyword_tags) OR 'lawn mower' = ANY(keyword_tags);
