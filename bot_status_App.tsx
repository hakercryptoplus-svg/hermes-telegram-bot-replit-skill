export default function App() {
  return (
    <div style={{
      minHeight: "100vh",
      background: "linear-gradient(135deg, #0f172a 0%, #1e293b 100%)",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      fontFamily: "'Segoe UI', system-ui, sans-serif",
      color: "#e2e8f0"
    }}>
      <div style={{ textAlign: "center", padding: "2rem" }}>
        <div style={{ fontSize: "4rem", marginBottom: "1rem" }}>⚕️</div>
        <h1 style={{
          fontSize: "2rem",
          fontWeight: 700,
          marginBottom: "0.5rem",
          background: "linear-gradient(90deg, #38bdf8, #818cf8)",
          WebkitBackgroundClip: "text",
          WebkitTextFillColor: "transparent"
        }}>
          Hermes Agent Bot
        </h1>
        <p style={{ color: "#94a3b8", marginBottom: "2rem", fontSize: "1rem" }}>
          Nous Research v0.15.2 · Powered by Gemini via Portkey
        </p>
        <div style={{
          display: "inline-flex",
          alignItems: "center",
          gap: "0.5rem",
          background: "rgba(34,197,94,0.1)",
          border: "1px solid rgba(34,197,94,0.3)",
          borderRadius: "9999px",
          padding: "0.5rem 1.25rem",
          fontSize: "0.9rem",
          color: "#4ade80"
        }}>
          <span style={{
            width: "8px", height: "8px",
            borderRadius: "50%",
            background: "#4ade80",
            boxShadow: "0 0 8px #4ade80",
            display: "inline-block",
            animation: "pulse 2s infinite"
          }} />
          Bot Online · Connected to Telegram
        </div>
        <p style={{ marginTop: "2rem", color: "#475569", fontSize: "0.8rem" }}>
          Message @Agent_x_claw_bot on Telegram to start a conversation
        </p>
      </div>
      <style>{`
        @keyframes pulse {
          0%, 100% { opacity: 1; }
          50% { opacity: 0.5; }
        }
      `}</style>
    </div>
  );
}
