import { useState, useEffect } from "react";
import { subscribeToasts, removeToast, Toast as ToastType } from "./useToast";

const KIND_STYLE: Record<string, { bg: string; border: string; color: string; icon: string }> = {
  error:   { bg: "#181825", border: "#f38ba8", color: "#f38ba8", icon: "✕" },
  success: { bg: "#181825", border: "#a6e3a1", color: "#a6e3a1", icon: "✓" },
  warning: { bg: "#181825", border: "#f9e2af", color: "#f9e2af", icon: "⚠" },
};

function Toast({ toast, onDismiss }: { toast: ToastType; onDismiss: () => void }) {
  const [visible, setVisible] = useState(true);
  const style = KIND_STYLE[toast.kind] ?? KIND_STYLE.warning;

  // Auto-dismiss timer
  useEffect(() => {
    if (toast.ttl <= 0) return;
    const id = setTimeout(() => {
      setVisible(false);
      setTimeout(onDismiss, 300); // fade out
    }, toast.ttl * 1000);
    return () => clearTimeout(id);
  }, [toast.ttl, onDismiss]);

  return (
    <div
      style={{
        background: style.bg,
        border: `1px solid ${style.border}`,
        borderRadius: 8,
        padding: "8px 12px",
        display: "flex",
        alignItems: "center",
        gap: 8,
        minWidth: 240,
        maxWidth: 360,
        boxShadow: "0 4px 12px rgba(0,0,0,0.4)",
        opacity: visible ? 1 : 0,
        transform: visible ? "translateX(0)" : "translateX(20px)",
        transition: "opacity 0.3s, transform 0.3s",
      }}
    >
      <span style={{ color: style.color, fontSize: 14, fontWeight: 700 }}>
        {style.icon}
      </span>
      <span style={{ flex: 1, fontSize: 12, color: "#cdd6f4", fontFamily: "monospace" }}>
        {toast.message}
      </span>
      <button
        onClick={() => { setVisible(false); setTimeout(onDismiss, 300); }}
        style={{
          background: "transparent",
          border: "none",
          color: "#585b70",
          cursor: "pointer",
          fontSize: 12,
          padding: "0 2px",
        }}
      >
        ✕
      </button>
    </div>
  );
}

export function ToastContainer() {
  const [toasts, setToasts] = useState<ToastType[]>([]);

  useEffect(() => {
    return subscribeToasts(setToasts);
  }, []);

  if (toasts.length === 0) return null;

  return (
    <div
      style={{
        position: "fixed",
        bottom: 80, // above permission panel
        left: 16,
        zIndex: 50,
        display: "flex",
        flexDirection: "column",
        gap: 6,
      }}
    >
      {toasts.map(t => (
        <Toast
          key={t.id}
          toast={t}
          onDismiss={() => removeToast(t.id)}
        />
      ))}
    </div>
  );
}
