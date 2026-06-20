/**
 * ╔════════════════════════════════════════════════════════════════════════╗
 * ║  GlobalRadar AI — 前端大屏实时联动组件                                    ║
 * ║  RadarStreamComponent.tsx                                                ║
 * ╠════════════════════════════════════════════════════════════════════════╣
 * ║  技术栈: React + TypeScript + Tailwind CSS + @supabase/supabase-js      ║
 * ║  功能:                                                                  ║
 * ║    • WebSocket 长连接监听 radar_clues INSERT 事件                         ║
 * ║    • 18 秒平滑流式浮现新线索                                              ║
 * ║    • 纯 2D 矢量金色闪烁微动效                                             ║
 * ║    • KPI +N 计数器实时刷新                                                ║
 * ╚════════════════════════════════════════════════════════════════════════╝
 *
 * 安装:
 *   npm install @supabase/supabase-js
 *
 * 使用:
 *   import RadarStreamComponent from './RadarStreamComponent';
 *   <RadarStreamComponent />
 */

import { useEffect, useState, useRef, useCallback } from "react";
import { createClient, SupabaseClient } from "@supabase/supabase-js";

// ─────────────────────────────────────────────────────────────────────────────
// 类型定义
// ─────────────────────────────────────────────────────────────────────────────

interface RadarClue {
  id: string;
  title: string;
  region: string;
  raw_url: string;
  status: string;
  created_at: string;
  source: string;
  score: number;
  email_masked: string | null;
  phone_masked: string | null;
  social_masked: string | null;
  is_decrypted: boolean;
  crawl_batch: string | null;
  crawl_metadata: Record<string, unknown> | null;
}

interface KPIStats {
  totalClues: number;
  todayClues: number;
  verifiedClues: number;
  decryptedClues: number;
}

interface PendingClue {
  clue: RadarClue;
  arrivalTime: number;
}

// ─────────────────────────────────────────────────────────────────────────────
// Supabase 配置
// ─────────────────────────────────────────────────────────────────────────────

const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL || "https://your-project.supabase.co";
const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY || "your-anon-key";

let supabase: SupabaseClient;
try {
  supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    realtime: {
      params: { eventsPerSecond: 10 },
    },
  });
} catch (error) {
  console.error("[GlobalRadar] Supabase 初始化失败:", error);
  // 降级: 创建空客户端, 后续会使用 Mock 数据
  supabase = createClient("https://placeholder.supabase.co", "placeholder");
}

// ─────────────────────────────────────────────────────────────────────────────
// 常量
// ─────────────────────────────────────────────────────────────────────────────

const STREAM_INTERVAL = 18_000; // 18 秒流式浮现
const MAX_VISIBLE_CLUES = 20;   // 最多显示 20 条
const INITIAL_FETCH_LIMIT = 10; // 初始加载 10 条历史数据

// ─────────────────────────────────────────────────────────────────────────────
// 区域 → 旗帜 Emoji 映射
// ─────────────────────────────────────────────────────────────────────────────

const REGION_FLAGS: Record<string, string> = {
  "United States": "🇺🇸",
  Germany: "🇩🇪",
  Australia: "🇦🇺",
  Canada: "🇨🇦",
  "United Kingdom": "🇬🇧",
  Mexico: "🇲🇽",
  "United Arab Emirates": "🇦🇪",
  Brazil: "🇧🇷",
  France: "🇫🇷",
  Japan: "🇯🇵",
};

function getFlag(region: string): string {
  return REGION_FLAGS[region] || "🌍";
}

// ─────────────────────────────────────────────────────────────────────────────
// 评分 → 颜色映射
// ─────────────────────────────────────────────────────────────────────────────

function getScoreColor(score: number): string {
  if (score >= 90) return "#F59E0B"; // 金色
  if (score >= 75) return "#10B981"; // 绿色
  if (score >= 60) return "#3B82F6"; // 蓝色
  return "#6B7280"; // 灰色
}

// ═══════════════════════════════════════════════════════════════════════════
// 主组件
// ═══════════════════════════════════════════════════════════════════════════

export default function RadarStreamComponent() {
  // ── 状态机 ──
  const [visibleClues, setVisibleClues] = useState<RadarClue[]>([]);
  const [pendingQueue, setPendingQueue] = useState<PendingClue[]>([]);
  const [kpiStats, setKpiStats] = useState<KPIStats>({
    totalClues: 0,
    todayClues: 0,
    verifiedClues: 0,
    decryptedClues: 0,
  });
  const [isConnected, setIsConnected] = useState(false);
  const [kpiFlash, setKpiFlash] = useState(false);
  const [newClueId, setNewClueId] = useState<string | null>(null);

  // ── Refs ──
  const pendingQueueRef = useRef<PendingClue[]>([]);
  const streamTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const channelRef = useRef<ReturnType<typeof supabase.channel> | null>(null);

  // ─────────────────────────────────────────────────────────────────
  // 同步 pendingQueue ref
  // ─────────────────────────────────────────────────────────────────
  useEffect(() => {
    pendingQueueRef.current = pendingQueue;
  }, [pendingQueue]);

  // ─────────────────────────────────────────────────────────────────
  // 初始加载历史数据
  // ─────────────────────────────────────────────────────────────────
  const loadInitialData = useCallback(async () => {
    try {
      const { data, error } = await supabase
        .from("radar_clues")
        .select("*")
        .order("created_at", { ascending: false })
        .limit(INITIAL_FETCH_LIMIT);

      if (error) {
        console.error("[GlobalRadar] 初始加载失败:", error);
        return;
      }

      if (data && data.length > 0) {
        // 倒序展示（最新在前）
        const clues = (data as RadarClue[]).reverse();
        setVisibleClues(clues);

        // KPI 初始化
        const today = new Date();
        today.setHours(0, 0, 0, 0);
        const todayCount = clues.filter(
          (c) => new Date(c.created_at) >= today
        ).length;

        setKpiStats({
          totalClues: clues.length,
          todayClues: todayCount,
          verifiedClues: clues.filter((c) => c.status === "verified").length,
          decryptedClues: clues.filter((c) => c.is_decrypted).length,
        });

        console.log(`[GlobalRadar] 初始加载 ${clues.length} 条线索`);
      }
    } catch (err) {
      console.error("[GlobalRadar] 初始加载异常:", err);
    }
  }, []);

  // ─────────────────────────────────────────────────────────────────
  // 流式出队 — 每 18 秒取一条
  // ─────────────────────────────────────────────────────────────────
  const dequeueNextClue = useCallback(() => {
    const queue = pendingQueueRef.current;
    if (queue.length === 0) return;

    const next = queue[0];
    setPendingQueue((prev) => prev.slice(1));

    // 线索入列可见列表
    setVisibleClues((prev) => {
      const updated = [next.clue, ...prev];
      return updated.slice(0, MAX_VISIBLE_CLUES);
    });

    // 触发金色闪烁动画
    setNewClueId(next.clue.id);
    setTimeout(() => setNewClueId(null), 2500);

    // KPI +N 闪烁
    setKpiFlash(true);
    setTimeout(() => setKpiFlash(false), 800);

    // KPI 更新
    setKpiStats((prev) => {
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const isToday = new Date(next.clue.created_at) >= today;
      return {
        totalClues: prev.totalClues + 1,
        todayClues: isToday ? prev.todayClues + 1 : prev.todayClues,
        verifiedClues:
          next.clue.status === "verified"
            ? prev.verifiedClues + 1
            : prev.verifiedClues,
        decryptedClues: prev.decryptedClues,
      };
    });

    console.log(
      `[GlobalRadar] ✨ 流式浮现新线索: ${next.clue.title} (${next.clue.region})`
    );
  }, []);

  // ─────────────────────────────────────────────────────────────────
  // 初始化 Realtime WebSocket 长连接
  // ─────────────────────────────────────────────────────────────────
  useEffect(() => {
    // 加载历史数据
    loadInitialData();

    // 创建 Realtime channel — 监听 radar_clues INSERT
    const channel = supabase
      .channel("radar-clues-realtime")
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "radar_clues",
        },
        (payload) => {
          const newClue = payload.new as RadarClue;
          console.log(
            `[GlobalRadar] 📡 收到 Realtime INSERT: ${newClue.title} (${newClue.region})`
          );

          // 加入待处理队列 — 不立即显示
          setPendingQueue((prev) => [
            ...prev,
            { clue: newClue, arrivalTime: Date.now() },
          ]);

          // KPI total +1（但 visibleClues 不变，等出队时再加）
          setKpiStats((prev) => ({
            ...prev,
            totalClues: prev.totalClues + 1,
          }));
          setKpiFlash(true);
          setTimeout(() => setKpiFlash(false), 800);
        }
      )
      .on(
        "postgres_changes",
        {
          event: "UPDATE",
          schema: "public",
          table: "radar_clues",
        },
        (payload) => {
          const updated = payload.new as RadarClue;
          console.log(
            `[GlobalRadar] 📝 收到 Realtime UPDATE: ${updated.id} → ${updated.status}`
          );

          // 更新可见列表中的对应线索
          setVisibleClues((prev) =>
            prev.map((c) => (c.id === updated.id ? updated : c))
          );

          if (updated.is_decrypted) {
            setKpiStats((prev) => ({
              ...prev,
              decryptedClues: prev.decryptedClues + 1,
            }));
          }
          if (updated.status === "verified") {
            setKpiStats((prev) => ({
              ...prev,
              verifiedClues: prev.verifiedClues + 1,
            }));
          }
        }
      )
      .subscribe((status) => {
        if (status === "SUBSCRIBED") {
          setIsConnected(true);
          console.log("[GlobalRadar] ✅ Realtime WebSocket 已连接");
        } else if (status === "CHANNEL_ERROR" || status === "TIMED_OUT") {
          setIsConnected(false);
          console.error("[GlobalRadar] ❌ Realtime 连接失败:", status);
        } else if (status === "CLOSED") {
          setIsConnected(false);
          console.log("[GlobalRadar] 🔌 Realtime 连接已关闭");
        }
      });

    channelRef.current = channel;

    // 启动 18 秒流式出队定时器
    streamTimerRef.current = setInterval(dequeueNextClue, STREAM_INTERVAL);

    // 清理
    return () => {
      if (streamTimerRef.current) {
        clearInterval(streamTimerRef.current);
      }
      if (channelRef.current) {
        supabase.removeChannel(channelRef.current);
      }
    };
  }, [loadInitialData, dequeueNextClue]);

  // ─────────────────────────────────────────────────────────────────
  // 解密操作（扣费后调用）
  // ─────────────────────────────────────────────────────────────────
  const handleDecrypt = useCallback(async (clueId: string) => {
    try {
      const { data, error } = await supabase.rpc("decrypt_clue", {
        p_clue_id: clueId,
      });

      if (error) {
        console.error("[GlobalRadar] 解密失败:", error);
        return;
      }

      if (data?.success) {
        // 更新本地状态
        setVisibleClues((prev) =>
          prev.map((c) =>
            c.id === clueId ? { ...c, is_decrypted: true } : c
          )
        );
        setKpiStats((prev) => ({
          ...prev,
          decryptedClues: prev.decryptedClues + 1,
        }));
        console.log("[GlobalRadar] 🔓 解密成功:", clueId);
      }
    } catch (err) {
      console.error("[GlobalRadar] 解密异常:", err);
    }
  }, []);

  // ═══════════════════════════════════════════════════════════════
  // 渲染
  // ═══════════════════════════════════════════════════════════════

  return (
    <div
      style={{
        background: "#0B0F19",
        minHeight: "100vh",
        fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, sans-serif",
        color: "#E2E8F0",
        overflow: "hidden",
      }}
    >
      {/* ── 顶部 KPI 大屏 ── */}
      <KpiDashboard
        stats={kpiStats}
        isConnected={isConnected}
        flash={kpiFlash}
        pendingCount={pendingQueue.length}
      />

      {/* ── 雷达扫描线 ── */}
      <RadarScanner active={isConnected} />

      {/* ── 线索流 ── */}
      <div
        style={{
          maxWidth: "900px",
          margin: "0 auto",
          padding: "24px 16px",
        }}
      >
        {/* 队列提示 */}
        {pendingQueue.length > 0 && (
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: "8px",
              padding: "8px 16px",
              marginBottom: "12px",
              background: "rgba(245, 158, 11, 0.08)",
              border: "1px solid rgba(245, 158, 11, 0.2)",
              borderRadius: "12px",
              fontSize: "13px",
              color: "#F59E0B",
            }}
          >
            <PulseDot />
            <span>
              {pendingQueue.length} 条新线索排队中，每 18 秒浮现 1 条
            </span>
          </div>
        )}

        {/* 线索卡片列表 */}
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            gap: "12px",
          }}
        >
          {visibleClues.length === 0 && (
            <div
              style={{
                textAlign: "center",
                padding: "60px 20px",
                color: "#4B5563",
                fontSize: "14px",
              }}
            >
              <RadarIcon spinning={isConnected} />
              <p style={{ marginTop: "16px" }}>
                {isConnected
                  ? "雷达已启动，等待线索信号..."
                  : "正在连接 Realtime 频道..."}
              </p>
            </div>
          )}

          {visibleClues.map((clue, index) => (
            <ClueCard
              key={clue.id}
              clue={clue}
              isNew={newClueId === clue.id}
              index={index}
              onDecrypt={handleDecrypt}
            />
          ))}
        </div>
      </div>

      {/* 内联样式 + 动画 */}
      <style>{GLOBAL_STYLES}</style>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: KPI 大屏
// ═══════════════════════════════════════════════════════════════════════════

function KpiDashboard({
  stats,
  isConnected,
  flash,
  pendingCount,
}: {
  stats: KPIStats;
  isConnected: boolean;
  flash: boolean;
  pendingCount: number;
}) {
  const items = [
    { label: "线索总量", value: stats.totalClues, color: "#F59E0B", icon: "📡" },
    { label: "今日新增", value: stats.todayClues, color: "#10B981", icon: "📈" },
    { label: "已验证", value: stats.verifiedClues, color: "#3B82F6", icon: "✓" },
    { label: "已解密", value: stats.decryptedClues, color: "#8B5CF6", icon: "🔓" },
  ];

  return (
    <div
      style={{
        background: "linear-gradient(135deg, #0F172A 0%, #111827 100%)",
        borderBottom: "1px solid rgba(245, 158, 11, 0.15)",
        padding: "20px 24px",
      }}
    >
      <div
        style={{
          maxWidth: "900px",
          margin: "0 auto",
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          gap: "16px",
          flexWrap: "wrap",
        }}
      >
        {/* 品牌 */}
        <div style={{ display: "flex", alignItems: "center", gap: "12px" }}>
          <RadarIcon spinning={isConnected} size={32} />
          <div>
            <div
              style={{
                fontSize: "18px",
                fontWeight: 800,
                color: "#F59E0B",
                letterSpacing: "0.5px",
              }}
            >
              GlobalRadar AI
            </div>
            <div style={{ fontSize: "11px", color: "#6B7280" }}>
              出海雷达 · 实时采购线索
            </div>
          </div>
        </div>

        {/* 连接状态 */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            gap: "6px",
            fontSize: "12px",
          }}
        >
          <div
            className={flash ? "kpi-flash" : ""}
            style={{
              width: "8px",
              height: "8px",
              borderRadius: "50%",
              background: isConnected ? "#10B981" : "#EF4444",
              boxShadow: isConnected
                ? "0 0 8px rgba(16, 185, 129, 0.6)"
                : "0 0 8px rgba(239, 68, 68, 0.6)",
              transition: "all 0.3s ease",
            }}
          />
          <span style={{ color: isConnected ? "#10B981" : "#EF4444" }}>
            {isConnected ? "实时连接中" : "断开连接"}
          </span>
          {pendingCount > 0 && (
            <span style={{ color: "#F59E0B", marginLeft: "4px" }}>
              · 队列 {pendingCount}
            </span>
          )}
        </div>
      </div>

      {/* KPI 卡片 */}
      <div
        style={{
          maxWidth: "900px",
          margin: "16px auto 0",
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(160px, 1fr))",
          gap: "12px",
        }}
      >
        {items.map((item) => (
          <div
            key={item.label}
            className={flash ? "kpi-card-flash" : ""}
            style={{
              background: "rgba(255, 255, 255, 0.03)",
              border: "1px solid rgba(255, 255, 255, 0.06)",
              borderRadius: "14px",
              padding: "16px",
              position: "relative",
              overflow: "hidden",
              transition: "all 0.4s ease",
            }}
          >
            {/* 左侧色条 */}
            <div
              style={{
                position: "absolute",
                left: 0,
                top: 0,
                bottom: 0,
                width: "3px",
                background: item.color,
                borderRadius: "14px 0 0 14px",
              }}
            />
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: "6px",
                marginBottom: "8px",
              }}
            >
              <span style={{ fontSize: "14px" }}>{item.icon}</span>
              <span style={{ fontSize: "12px", color: "#9CA3AF" }}>
                {item.label}
              </span>
            </div>
            <div
              className="kpi-number"
              style={{
                fontSize: "28px",
                fontWeight: 800,
                color: item.color,
                fontVariantNumeric: "tabular-nums",
                lineHeight: 1,
              }}
            >
              {item.value.toLocaleString()}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 雷达扫描线
// ═══════════════════════════════════════════════════════════════════════════

function RadarScanner({ active }: { active: boolean }) {
  return (
    <div
      style={{
        height: "2px",
        background: "rgba(245, 158, 11, 0.1)",
        position: "relative",
        overflow: "hidden",
      }}
    >
      {active && (
        <div
          style={{
            position: "absolute",
            top: 0,
            left: "-30%",
            width: "30%",
            height: "100%",
            background:
              "linear-gradient(90deg, transparent, #F59E0B, transparent)",
            animation: "radar-scan 3s linear infinite",
          }}
        />
      )}
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 线索卡片
// ═══════════════════════════════════════════════════════════════════════════

function ClueCard({
  clue,
  isNew,
  index,
  onDecrypt,
}: {
  clue: RadarClue;
  isNew: boolean;
  index: number;
  onDecrypt: (id: string) => void;
}) {
  const [isDecrypting, setIsDecrypting] = useState(false);

  const handleDecrypt = async () => {
    setIsDecrypting(true);
    await onDecrypt(clue.id);
    setIsDecrypting(false);
  };

  return (
    <div
      className={`clue-card ${isNew ? "clue-card-new" : ""}`}
      style={{
        background: "rgba(255, 255, 255, 0.03)",
        border: isNew
          ? "1px solid rgba(245, 158, 11, 0.4)"
          : "1px solid rgba(255, 255, 255, 0.06)",
        borderRadius: "16px",
        padding: "18px 20px",
        position: "relative",
        overflow: "hidden",
        transition: "all 0.4s cubic-bezier(0.16, 1, 0.3, 1)",
        animationDelay: `${index * 0.05}s`,
      }}
    >
      {/* 新线索金色闪烁微动效 — 纯 2D 矢量 */}
      {isNew && (
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: "2px",
            background:
              "linear-gradient(90deg, transparent, #F59E0B 20%, #FBBF24 50%, #F59E0B 80%, transparent)",
            animation: "gold-shimmer 2.5s ease-out",
          }}
        />
      )}

      {/* 新线索角标 */}
      {isNew && (
        <div
          style={{
            position: "absolute",
            top: "8px",
            right: "12px",
            padding: "2px 8px",
            background: "linear-gradient(135deg, #F59E0B, #D97706)",
            borderRadius: "6px",
            fontSize: "10px",
            fontWeight: 700,
            color: "#0B0F19",
            animation: "badge-pulse 1s ease-out",
          }}
        >
          NEW
        </div>
      )}

      {/* 标题行 */}
      <div
        style={{
          display: "flex",
          alignItems: "flex-start",
          gap: "12px",
          marginBottom: "12px",
        }}
      >
        {/* 评分圆环 — 纯 SVG 矢量 */}
        <ScoreRing score={clue.score} color={getScoreColor(clue.score)} />

        <div style={{ flex: 1, minWidth: 0 }}>
          <h3
            style={{
              fontSize: "15px",
              fontWeight: 600,
              color: "#F1F5F9",
              margin: 0,
              lineHeight: 1.4,
              overflow: "hidden",
              textOverflow: "ellipsis",
              whiteSpace: "nowrap",
            }}
          >
            {clue.title}
          </h3>
          <div
            style={{
              display: "flex",
              alignItems: "center",
              gap: "8px",
              marginTop: "6px",
              fontSize: "12px",
              color: "#9CA3AF",
            }}
          >
            <span>{getFlag(clue.region)}</span>
            <span>{clue.region}</span>
            <span style={{ color: "#374151" }}>·</span>
            <span>{clue.source}</span>
            <span style={{ color: "#374151" }}>·</span>
            <span>
              {new Date(clue.created_at).toLocaleString("zh-CN", {
                month: "short",
                day: "numeric",
                hour: "2-digit",
                minute: "2-digit",
              })}
            </span>
          </div>
        </div>
      </div>

      {/* 脱敏信息 */}
      <div
        style={{
          display: "flex",
          gap: "8px",
          flexWrap: "wrap",
          marginBottom: "14px",
        }}
      >
        {clue.email_masked && (
          <MaskedField label="邮箱" value={clue.email_masked} decrypted={clue.is_decrypted} />
        )}
        {clue.phone_masked && (
          <MaskedField label="电话" value={clue.phone_masked} decrypted={clue.is_decrypted} />
        )}
        {clue.social_masked && (
          <MaskedField label="社交" value={clue.social_masked} decrypted={clue.is_decrypted} />
        )}
      </div>

      {/* 操作按钮 */}
      <div style={{ display: "flex", gap: "8px" }}>
        {!clue.is_decrypted ? (
          <button
            onClick={handleDecrypt}
            disabled={isDecrypting}
            style={{
              padding: "7px 16px",
              background: isDecrypting
                ? "rgba(245, 158, 11, 0.3)"
                : "linear-gradient(135deg, #F59E0B, #D97706)",
              color: "#0B0F19",
              fontSize: "12px",
              fontWeight: 700,
              border: "none",
              borderRadius: "8px",
              cursor: isDecrypting ? "wait" : "pointer",
              transition: "all 0.2s ease",
            }}
          >
            {isDecrypting ? "解密中..." : "🔓 解密 (¥0.5)"}
          </button>
        ) : (
          <button
            style={{
              padding: "7px 16px",
              background: "rgba(16, 185, 129, 0.15)",
              border: "1px solid rgba(16, 185, 129, 0.3)",
              color: "#10B981",
              fontSize: "12px",
              fontWeight: 600,
              borderRadius: "8px",
              cursor: "default",
            }}
          >
            ✓ 已解密
          </button>
        )}
        <a
          href={clue.raw_url}
          target="_blank"
          rel="noopener noreferrer"
          style={{
            padding: "7px 16px",
            background: "rgba(255, 255, 255, 0.05)",
            border: "1px solid rgba(255, 255, 255, 0.1)",
            color: "#9CA3AF",
            fontSize: "12px",
            textDecoration: "none",
            borderRadius: "8px",
            transition: "all 0.2s ease",
          }}
        >
          查看来源 ↗
        </a>
      </div>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 评分圆环 (纯 SVG 矢量)
// ═══════════════════════════════════════════════════════════════════════════

function ScoreRing({ score, color }: { score: number; color: string }) {
  const radius = 18;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference - (score / 100) * circumference;

  return (
    <div style={{ position: "relative", width: "44px", height: "44px", flexShrink: 0 }}>
      <svg width="44" height="44" viewBox="0 0 44 44">
        {/* 背景圆 */}
        <circle
          cx="22"
          cy="22"
          r={radius}
          fill="none"
          stroke="rgba(255,255,255,0.06)"
          strokeWidth="3"
        />
        {/* 进度圆 */}
        <circle
          cx="22"
          cy="22"
          r={radius}
          fill="none"
          stroke={color}
          strokeWidth="3"
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={offset}
          transform="rotate(-90 22 22)"
          style={{ transition: "stroke-dashoffset 0.6s ease" }}
        />
      </svg>
      <span
        style={{
          position: "absolute",
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          fontSize: "12px",
          fontWeight: 700,
          color: color,
          fontVariantNumeric: "tabular-nums",
        }}
      >
        {score}
      </span>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 脱敏字段
// ═══════════════════════════════════════════════════════════════════════════

function MaskedField({
  label,
  value,
  decrypted,
}: {
  label: string;
  value: string;
  decrypted: boolean;
}) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: "4px",
        padding: "4px 10px",
        background: "rgba(255, 255, 255, 0.04)",
        borderRadius: "8px",
        fontSize: "11px",
      }}
    >
      <span style={{ color: "#6B7280" }}>{label}</span>
      <span
        style={{
          color: decrypted ? "#10B981" : "#9CA3AF",
          filter: decrypted ? "none" : "blur(3px)",
          transition: "filter 0.4s ease",
          userSelect: "none",
        }}
      >
        {value}
      </span>
    </div>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 雷达图标 (纯 SVG 矢量)
// ═══════════════════════════════════════════════════════════════════════════

function RadarIcon({ spinning, size = 28 }: { spinning: boolean; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" fill="none">
      {/* 外圈 */}
      <circle
        cx="16"
        cy="16"
        r="14"
        stroke="rgba(245, 158, 11, 0.2)"
        strokeWidth="1"
        fill="none"
      />
      {/* 中圈 */}
      <circle
        cx="16"
        cy="16"
        r="9"
        stroke="rgba(245, 158, 11, 0.15)"
        strokeWidth="1"
        fill="none"
      />
      {/* 内圈 */}
      <circle
        cx="16"
        cy="16"
        r="4"
        stroke="rgba(245, 158, 11, 0.1)"
        strokeWidth="1"
        fill="none"
      />
      {/* 十字线 */}
      <line x1="16" y1="2" x2="16" y2="30" stroke="rgba(245,158,11,0.1)" strokeWidth="0.5" />
      <line x1="2" y1="16" x2="30" y2="16" stroke="rgba(245,158,11,0.1)" strokeWidth="0.5" />
      {/* 扫描线 */}
      {spinning && (
        <g style={{ transformOrigin: "16px 16px", animation: "radar-spin 3s linear infinite" }}>
          <defs>
            <linearGradient id="radar-beam" x1="0%" y1="0%" x2="100%" y2="0%">
              <stop offset="0%" stopColor="#F59E0B" stopOpacity="0" />
              <stop offset="100%" stopColor="#F59E0B" stopOpacity="0.6" />
            </linearGradient>
          </defs>
          <path
            d="M 16 16 L 16 2 A 14 14 0 0 1 28 9 Z"
            fill="url(#radar-beam)"
          />
          <line x1="16" y1="16" x2="16" y2="2" stroke="#F59E0B" strokeWidth="1.5" />
        </g>
      )}
      {/* 中心点 */}
      <circle cx="16" cy="16" r="2" fill="#F59E0B" />
    </svg>
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 子组件: 脉冲圆点
// ═══════════════════════════════════════════════════════════════════════════

function PulseDot() {
  return (
    <div
      style={{
        width: "8px",
        height: "8px",
        borderRadius: "50%",
        background: "#F59E0B",
        animation: "pulse-dot 1.5s ease-in-out infinite",
      }}
    />
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 全局动画样式
// ═══════════════════════════════════════════════════════════════════════════

const GLOBAL_STYLES = `
  /* 雷达旋转 */
  @keyframes radar-spin {
    from { transform: rotate(0deg); }
    to   { transform: rotate(360deg); }
  }

  /* 雷达扫描线 */
  @keyframes radar-scan {
    0%   { left: -30%; }
    100% { left: 100%; }
  }

  /* 金色闪烁微动效 — 新线索 */
  @keyframes gold-shimmer {
    0% {
      opacity: 0;
      transform: scaleX(0);
    }
    20% {
      opacity: 1;
      transform: scaleX(1);
    }
    100% {
      opacity: 0;
      transform: scaleX(1);
    }
  }

  /* 新线索卡片入场 */
  .clue-card-new {
    animation: card-enter 0.6s cubic-bezier(0.16, 1, 0.3, 1) both;
  }

  @keyframes card-enter {
    from {
      opacity: 0;
      transform: translateY(-12px) scale(0.97);
      box-shadow: 0 0 30px rgba(245, 158, 11, 0.3);
    }
    to {
      opacity: 1;
      transform: translateY(0) scale(1);
      box-shadow: 0 0 0 rgba(245, 158, 11, 0);
    }
  }

  /* KPI 数字 +N 闪烁 */
  .kpi-flash {
    animation: kpi-pulse 0.8s ease-out;
  }

  @keyframes kpi-pulse {
    0%   { transform: scale(1); box-shadow: 0 0 0 rgba(245,158,11,0); }
    30%  { transform: scale(1.3); box-shadow: 0 0 12px rgba(245,158,11,0.8); }
    100% { transform: scale(1); box-shadow: 0 0 0 rgba(245,158,11,0); }
  }

  /* KPI 卡片闪烁 */
  .kpi-card-flash {
    border-color: rgba(245, 158, 11, 0.4) !important;
    box-shadow: 0 0 16px rgba(245, 158, 11, 0.15);
  }

  /* NEW 角标脉冲 */
  @keyframes badge-pulse {
    0%   { transform: scale(0.5); opacity: 0; }
    50%  { transform: scale(1.1); opacity: 1; }
    100% { transform: scale(1); opacity: 1; }
  }

  /* 脉冲圆点 */
  @keyframes pulse-dot {
    0%, 100% { transform: scale(1); opacity: 1; }
    50%      { transform: scale(1.5); opacity: 0.5; }
  }

  /* KPI 数字过渡 */
  .kpi-number {
    transition: all 0.3s cubic-bezier(0.16, 1, 0.3, 1);
  }

  /* 卡片悬停 */
  .clue-card:hover {
    background: rgba(255, 255, 255, 0.05) !important;
    border-color: rgba(245, 158, 11, 0.2) !important;
    transform: translateY(-1px);
  }
`;
