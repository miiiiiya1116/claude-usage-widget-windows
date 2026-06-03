// Claude 使用状況ウィジェットの純粋ロジック（座標計算・位置の永続化）。

export const PANEL_WIDTH = 320; // パネル幅(px)。widget の width と一致させる
export const MARGIN = 8; // 上端からのマージン(px)
export const MARGIN_RIGHT = 8; // 右端からのマージン(px)
export const DEFAULT_PANEL_HEIGHT = 120; // DOM 高さ取得不可時のフォールバック(px)

// 初期位置（右上）。上=MARGIN, 右=MARGIN_RIGHT の非対称マージン
export function initialPos(screenW, panelW = PANEL_WIDTH) {
  return { x: Math.max(0, screenW - panelW - MARGIN_RIGHT), y: MARGIN };
}

// パネルが画面外に消えないようクランプ。
// margin>0 を渡すと端から余白を保ち、端ぴったりに張り付かない。
export function clampPos(x, y, panelW, panelH, screenW, screenH, margin = 0) {
  const maxX = Math.max(margin, screenW - panelW - margin);
  const maxY = Math.max(margin, screenH - panelH - margin);
  return {
    x: Math.min(Math.max(margin, x), maxX),
    y: Math.min(Math.max(margin, y), maxY),
  };
}

export function serializePos(pos) {
  return JSON.stringify({ x: pos.x, y: pos.y });
}

export function parsePos(raw) {
  try {
    const o = JSON.parse(raw);
    if (o && typeof o.x === "number" && typeof o.y === "number") {
      return { x: o.x, y: o.y };
    }
  } catch {}
  return null;
}
