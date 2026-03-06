import React, { useState } from "react";
import { useChat } from "@ai-sdk/react";
import { DefaultChatTransport } from "ai";

// Derive API URL from the current page host — same host, port 28601
const apiUrl =
  typeof window !== "undefined"
    ? `${window.location.protocol}//${window.location.hostname}:28601/chat`
    : "http://localhost:28601/chat";

export default function Chat() {
  const [input, setInput] = useState("");
  const { messages, sendMessage, status } = useChat({
    transport: new DefaultChatTransport({ api: apiUrl }),
  });

  const isLoading = status !== "ready";

  return (
    <div style={{ maxWidth: 640, margin: "40px auto", fontFamily: "system-ui" }}>
      <h2>OCaml AI SDK Chat</h2>
      <div
        style={{
          border: "1px solid #ddd",
          borderRadius: 8,
          padding: 16,
          minHeight: 300,
          maxHeight: 500,
          overflowY: "auto",
          marginBottom: 16,
          background: "#fafafa",
        }}
      >
        {messages.length === 0 && (
          <p style={{ color: "#999" }}>Send a message to start chatting...</p>
        )}
        {messages.map((m) => (
          <div
            key={m.id}
            style={{
              marginBottom: 12,
              padding: 8,
              borderRadius: 6,
              background: m.role === "user" ? "#e3f2fd" : "#fff",
              border: "1px solid #eee",
            }}
          >
            <strong>{m.role === "user" ? "You" : "Claude"}</strong>
            <div style={{ whiteSpace: "pre-wrap", marginTop: 4 }}>
              {m.parts.map((part, i) => {
                if (part.type === "text") return <span key={i}>{part.text}</span>;
                if (part.type === "tool-invocation")
                  return (
                    <div
                      key={i}
                      style={{
                        background: "#f5f5f5",
                        padding: 8,
                        borderRadius: 4,
                        fontSize: 13,
                        marginTop: 4,
                      }}
                    >
                      Tool: {part.toolInvocation.toolName}
                      {part.toolInvocation.state === "result" && (
                        <span> = {JSON.stringify(part.toolInvocation.result)}</span>
                      )}
                    </div>
                  );
                return null;
              })}
            </div>
          </div>
        ))}
      </div>
      <form
        onSubmit={(e) => {
          e.preventDefault();
          if (input.trim()) {
            sendMessage({ text: input });
            setInput("");
          }
        }}
        style={{ display: "flex", gap: 8 }}
      >
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder="Type a message..."
          disabled={isLoading}
          style={{
            flex: 1,
            padding: "8px 12px",
            borderRadius: 6,
            border: "1px solid #ccc",
            fontSize: 14,
          }}
        />
        <button
          type="submit"
          disabled={isLoading || !input.trim()}
          style={{
            padding: "8px 20px",
            borderRadius: 6,
            border: "none",
            background: isLoading ? "#ccc" : "#1976d2",
            color: "#fff",
            cursor: isLoading ? "default" : "pointer",
            fontSize: 14,
          }}
        >
          {isLoading ? "..." : "Send"}
        </button>
      </form>
      <p style={{ marginTop: 12, fontSize: 12, color: "#999" }}>
        Powered by OCaml AI SDK + Anthropic Claude
      </p>
    </div>
  );
}
