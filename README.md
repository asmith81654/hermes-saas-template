# Hermes Agent Railway SaaS

<p align="center">
  <strong>一用戶一實例 · IM 原生體驗 · 全自動部署 · 即插即用</strong>
</p>

<p align="center">
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <a href="https://railway.app/"><img src="https://img.shields.io/badge/Deploy%20on-Railway-%230A0A0A?logo=railway" alt="Deploy on Railway"></a>
  <a href="https://github.com/nousresearch/hermes-agent"><img src="https://img.shields.io/badge/Powered%20by-Hermes%20Agent-purple" alt="Powered by Hermes Agent"></a>
  <a href="https://www.python.org/"><img src="https://img.shields.io/badge/Python-3.12%2B-blue?logo=python" alt="Python 3.12+"></a>
</p>

---

## 目錄

- [概述](#概述)
- [系統架構](#系統架構)
- [前置需求](#前置需求)
- [快速開始](#快速開始)
- [配置指南](#配置指南)
- [部署指南](#部署指南)
- [腳本參考](#腳本參考)
- [環境變量參考](#環境變量參考)
- [Web 管理後台](#web-管理後台)
- [日常維護](#日常維護)
- [故障排除](#故障排除)
- [安全注意事項](#安全注意事項)
- [常見問題](#常見問題)

---

## 概述

### 這是什麼？

**Hermes Agent Railway SaaS** 是一個基於 [Hermes Agent](https://github.com/nousresearch/hermes-agent) 的 AI 助手 SaaS 平台自動化部署系統。它將 Hermes Agent（一個自我改進的 AI Agent 平台）部署在 [Railway.app](https://railway.app) 上，實現「一用戶一獨立實例」的 SaaS 架構。

每位付費用戶獲得一個完全隔離的 Railway 專案，其中運行著專屬的 Hermes Agent 實例，並配有持久化記憶儲存。用戶透過他們日常使用的即時通訊工具（Telegram、Slack、Discord、WhatsApp 等）與 AI 進行對話，無需安裝任何新應用。

### 為什麼需要這個？

傳統的 AI 助手 SaaS 平台面臨幾個核心挑戰：

| 挑戰 | 本系統解決方案 |
|------|----------------|
| **數據隔離** | 每位用戶獨立的 Railway 專案，對話歷史、記憶、配置完全隔離 |
| **部署複雜性** | 全自動化腳本管理整個生命週期（建立 → 部署 → 配置 → 回收） |
| **IM 整合** | 內建多平台 IM Gateway 支援，用戶在熟悉工具中使用 |
| **成本控制** | 每用戶獨立計費，Token 用量精確追蹤，無交叉補貼 |
| **規模化運營** | 從 1 個用戶到 10,000 個用戶，同一套腳本即可管理 |

### 核心功能

- **一用戶一專案隔離** — 每位用戶在 Railway 上擁有完全獨立的專案，數據互不干擾
- **持久化記憶** — 基於 `/data` 磁碟區的 SQLite 記憶儲存，重啟不丟失
- **IM 原生體驗** — 支援 Telegram、Slack、Discord、WhatsApp、Teams 等主流平台
- **自動化配置** — 所有 Agent 行為通過環境變量注入，無需修改程式碼
- **Web 管理後台** — 每個實例內建儀表板，管理 Gateway 狀態、配置和日誌
- **全生命週期管理** — 從創建專案、注入配置到回收資源，全腳本化操作
- **批量部署** — 支援從檔案批量創建多個用戶實例
- **多 Agent 支援** — 用戶可在系統 Agent 和自建 Agent 之間自由切換

---

## 系統架構

### 架構全景圖

```
┌──────────────────────────────────────────────────────────────┐
│                     Railway 雲平台                             │
│                                                               │
│  ┌─────────────────────────┐  ┌─────────────────────────┐    │
│  │    用戶專案 (User-001)   │  │    用戶專案 (User-002)   │    │
│  │                         │  │                         │    │
│  │  ┌───────────────────┐  │  │  ┌───────────────────┐  │    │
│  │  │   Docker Container │  │  │  │   Docker Container │  │    │
│  │  │                   │  │  │  │                   │  │    │
│  │  │  ┌─────────────┐  │  │  │  │  ┌─────────────┐  │  │    │
│  │  │  │ Hermes Agent │  │  │  │  │ │ Hermes Agent │  │  │    │
│  │  │  │  (核心引擎)   │  │  │  │  │ │  (核心引擎)   │  │  │    │
│  │  │  └──────┬──────┘  │  │  │  │  └──────┬──────┘  │  │    │
│  │  │         │         │  │  │  │         │         │  │    │
│  │  │  ┌──────┴──────┐  │  │  │  │  ┌──────┴──────┐  │  │    │
│  │  │  │ IM Gateways │  │  │  │  │  │ IM Gateways │  │  │    │
│  │  │  │ · Telegram  │  │  │  │  │  │ · Slack     │  │  │    │
│  │  │  │ · Slack     │  │  │  │  │  │ · Discord   │  │  │    │
│  │  │  │ · Discord   │  │  │  │  │  │ · WhatsApp  │  │  │    │
│  │  │  │ · WhatsApp  │  │  │  │  │  │ · Teams     │  │  │    │
│  │  │  └─────────────┘  │  │  │  │  └─────────────┘  │  │    │
│  │  │                   │  │  │  │                   │  │    │
│  │  │  ┌─────────────┐  │  │  │  │  ┌─────────────┐  │  │    │
│  │  │  │  Web 儀表板  │  │  │  │  │  │  Web 儀表板  │  │  │    │
│  │  │  │  :8080      │  │  │  │  │  │  :8080      │  │  │    │
│  │  │  └─────────────┘  │  │  │  │  └─────────────┘  │  │    │
│  │  └───────────────────┘  │  │  │  └───────────────────┘  │    │
│  │           │             │  │  │           │             │    │
│  │     ┌─────┴─────┐       │  │  │     ┌─────┴─────┐       │    │
│  │     │ /data Vol │       │  │  │     │ /data Vol │       │    │
│  │     │ · sessions│       │  │  │     │ · sessions│       │    │
│  │     │ · skills  │       │  │  │     │ · skills  │       │    │
│  │     │ · workspace│      │  │  │     │ · workspace│      │    │
│  │     │ · pairing │       │  │  │     │ · pairing │       │    │
│  │     │ · logs    │       │  │  │     │ · logs    │       │    │
│  │     │ · config  │       │  │  │     │ · config  │       │    │
│  │     └───────────┘       │  │  │     └───────────┘       │    │
│  └─────────────────────────┘  │  └─────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
         │                                  │
    ┌────┴────┐                        ┌────┴────┐
    │Telegram │                        │  Slack  │
    │  Bot    │                        │  Bot    │
    └────┬────┘                        └────┬────┘
         │                                  │
    ┌────┴────┐                        ┌────┴────┐
    │ 用戶 #1  │                        │ 用戶 #2  │
    └─────────┘                        └─────────┘
```

### 核心組件說明

| 組件 | 說明 |
|------|------|
| **Railway 雲平台** | 託管所有用戶實例的 PaaS 平台，提供 Docker 容器運行、磁碟區掛載、健康檢查 |
| **Docker Container** | 每個用戶專案運行一個容器，內含 Hermes Agent + Web 伺服器 + IM Gateways |
| **Hermes Agent** | 核心 AI 引擎，負責 LLM 推理、對話管理、工具調用 |
| **IM Gateways** | 連接各即時通訊平台的橋樑，將 IM 訊息轉發給 Agent，並將回應傳回 |
| **Web 儀表板** | 基於 Starlette 的輕量級管理後台，管理 Gateway、配置和監控 |
| **/data 磁碟區** | Railway 持久化磁碟區，儲存對話歷史、技能、配置、配對資訊和日誌 |

### 數據流

```
用戶在 IM 發送訊息
       │
       ▼
  IM Gateway (如 Telegram Bot) 接收訊息
       │
       ▼
  Gateway 轉發訊息至 Hermes Agent
       │
       ▼
  Hermes Agent 處理請求:
  · 讀取對話歷史 (從 /data/sessions)
  · 執行工具調用 (如需要)
  · 調用 LLM API (OpenRouter / OpenAI / DeepSeek ...)
       │
       ▼
  Agent 生成回應
       │
       ▼
  Gateway 將回應發送回 IM 平台
       │
       ▼
  用戶在 IM 中看到 AI 回應
```

---

## 前置需求

### 必要條件

在開始之前，你需要準備以下內容：

#### 1. Railway 帳號

- 在 [Railway.app](https://railway.app) 註冊帳號
- 取得 API Token（前往 Railway 控制台 → Settings → API Tokens）
- 確保帳號有足夠的資源配額來建立多個專案

```bash
# 設定 Railway Token 為環境變量（所有腳本都需要此變量）
export RAILWAY_TOKEN="your-railway-api-token-here"
```

#### 2. GitHub 儲存庫

你需要一個包含 Hermes Agent 程式碼的 GitHub 儲存庫。Railway 會從該儲存庫自動部署。

- 方案一：使用本專案模板（推薦）
- 方案二：Fork [hermes-agent-railway-template](https://github.com/arjunkomath/hermes-agent-railway-template) 並加入本專案的腳本

#### 3. LLM API 金鑰

至少需要一個 LLM Provider 的 API 金鑰：

| Provider | 獲取方式 | 環境變量 |
|----------|---------|---------|
| **OpenRouter**（推薦） | [openrouter.ai/keys](https://openrouter.ai/keys) | `OPENROUTER_API_KEY` |
| **OpenAI** | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) | `OPENAI_API_KEY` |
| **DeepSeek** | [platform.deepseek.com/api_keys](https://platform.deepseek.com/api_keys) | `DEEPSEEK_API_KEY` |
| **Anthropic** | [console.anthropic.com/keys](https://console.anthropic.com/keys) | `ANTHROPIC_API_KEY` |
| **Google AI** | [aistudio.google.com/apikey](https://aistudio.google.com/apikey) | `GOOGLE_API_KEY` |
| **Groq** | [console.groq.com/keys](https://console.groq.com/keys) | `GROQ_API_KEY` |
| **xAI** | [x.ai/api](https://x.ai/api) | `XAI_API_KEY` |
| **Together AI** | [api.together.xyz](https://api.together.xyz) | `TOGETHER_API_KEY` |

> **建議：** 使用 OpenRouter 作為主要 Provider，它提供統一的 API 端點，能存取數百種模型，簡化金鑰管理。

#### 4. IM Bot Token（可選，但在生產環境必需）

根據你想支援的平台準備 Bot Token：

| 平台 | 獲取方式 | 環境變量 |
|------|---------|---------|
| **Telegram** | 透過 [@BotFather](https://t.me/BotFather) 創建 | `TELEGRAM_BOT_TOKEN` |
| **Slack** | [api.slack.com/apps](https://api.slack.com/apps) 創建應用 | `SLACK_BOT_TOKEN`、`SLACK_APP_TOKEN` |
| **Discord** | [discord.com/developers](https://discord.com/developers) 創建應用 | `DISCORD_BOT_TOKEN` |
| **WhatsApp** | 透過 WhatsApp Business API | `WHATSAPP_TOKEN` |
| **Microsoft Teams** | Azure AD 應用註冊 | `MSTEAMS_CLIENT_ID` |
| **Matrix** | 自託管或公有 homeserver | `MATRIX_HOMESERVER` |

> **關於 Bot 池：** 在生產環境中，個人 IM 平台（如 Telegram）需要預先建立一批 Bot 並存入資源池，每位用戶分配一個專屬 Bot。詳見 [配置指南 - Bot 池管理](#bot-池管理)。

#### 5. 用戶配置資料

每位用戶需要一個 JSON 配置檔案，包含其 LLM 設定、IM Bot Token 和 Agent 行為設定。詳見 [配置指南](#配置指南)。

---

## 快速開始

### 最快部署路徑（5 分鐘內部署第一個用戶）

```bash
# 步驟 1：複製環境變量範本並編輯
cp .env.example .env
# 編輯 .env，填入你的 LLM API 金鑰和 Railway Token

# 步驟 2：載入環境變量
source .env

# 步驟 3：確認 Railway Token 已設定
echo $RAILWAY_TOKEN

# 步驟 4：準備用戶配置檔案
mkdir -p configs
cat > configs/user-001.json <<'EOF'
{
  "user_id": "user-001",
  "agent_name": "小助手",
  "agent_system_prompt": "你是一位樂於助人的 AI 助手，使用繁體中文回答用戶的各種問題。你的回答應該清晰、友善且有幫助。",
  "model": "openrouter/openai/gpt-4o",
  "telegram_bot_token": "1234567890:YOUR_TELEGRAM_BOT_TOKEN_HERE",
  "llm_api_key": "${OPENROUTER_API_KEY}"
}
EOF

# 步驟 5：執行完整部署
./scripts/full-deploy.sh \
  --user-id user-001 \
  --config configs/user-001.json
```

部署完成後，腳本會輸出：
- 用戶的 Railway 專案 URL
- Web 儀表板位址
- 健康檢查狀態
- IM Bot 綁定連結

### 驗證部署

```bash
# 檢查 Railway 專案狀態
railway status --project <project-id>

# 檢查服務健康狀態
curl https://<your-service-url>.up.railway.app/health

# 查看部署日誌
railway logs --project <project-id>
```

### 本地開發測試

```bash
# 使用 Docker Compose 在本機啟動服務
docker compose up --build

# 服務啟動後可訪問：
# · Web 儀表板: http://localhost:8080
# · 健康檢查: http://localhost:8080/health
```

---

## 配置指南

### 配置層級架構

系統採用四層配置架構，靈活且安全：

```
┌──────────────────────────────────────────┐
│            平台級配置（運營方設定）          │
│  · LLM Provider API Key                  │
│  · Railway Token                         │
│  · 基礎設施參數                            │
├──────────────────────────────────────────┤
│            方案級配置（運營方設定）          │
│  · 訂閱方案 Token 配額                     │
│  · 可用模型列表                            │
│  · 功能開關                                │
├──────────────────────────────────────────┤
│            用戶級配置（系統自動）           │
│  · 專屬 Bot Token                         │
│  · IM 綁定 ID                             │
│  · 代理 API Key                           │
├──────────────────────────────────────────┤
│            Agent 級配置（用戶自定義）        │
│  · System Prompt                         │
│  · Agent 名稱                             │
│  · 可用工具                                │
└──────────────────────────────────────────┘
```

### 用戶配置 JSON 檔案格式

每位用戶的配置以 JSON 檔案儲存，完整結構如下：

```json
{
  "user_id": "user-001",
  "email": "user@example.com",
  "agent_name": "小幫手",
  "agent_system_prompt": "你是一位專業的 AI 助手...",
  "model": "openrouter/openai/gpt-4o",
  "tools": "web_search,code_execution,file_reader",
  "telegram_bot_token": "1234567890:AA...",
  "slack_bot_token": "xoxb-...",
  "slack_app_token": "xapp-...",
  "discord_bot_token": "MT...",
  "llm_api_key": "sk-or-...",
  "monthly_token_quota": 1000000,
  "subscription_tier": "pro"
}
```

### 欄位說明

| 欄位 | 類型 | 必填 | 說明 |
|------|------|------|------|
| `user_id` | string | 是 | 用戶唯一識別碼，用於命名 Railway 專案 |
| `email` | string | 否 | 用戶電子郵件，用於發送歡迎通知 |
| `agent_name` | string | 否 | Agent 顯示名稱，預設 "Hermes Assistant" |
| `agent_system_prompt` | string | 是 | 定義 Agent 行為和個性的系統提示詞 |
| `model` | string | 否 | LLM 模型識別碼，預設 `openrouter/openai/gpt-4o` |
| `tools` | string | 否 | 可用工具列表（逗號分隔） |
| `telegram_bot_token` | string | 否 | Telegram Bot Token |
| `slack_bot_token` | string | 否 | Slack Bot User OAuth Token |
| `slack_app_token` | string | 否 | Slack App-Level Token |
| `discord_bot_token` | string | 否 | Discord Bot Token |
| `llm_api_key` | string | 是 | LLM Provider 的 API 金鑰（或代理 Key） |
| `monthly_token_quota` | number | 否 | 月度 Token 配額上限 |
| `subscription_tier` | string | 否 | 訂閱方案（free / pro / enterprise） |

### 配置檔案範本

本專案提供一個配置範本檔案 `scripts/config-template.json`，可作為起點：

```bash
# 複製範本並編輯
cp scripts/config-template.json configs/user-002.json
```

### LLM 模型選擇

Hermes Agent 支援透過 OpenRouter 存取數百種模型。以下是常用模型選項：

```json
// 使用 OpenRouter（推薦 — 自動負載均衡和容錯轉移）
"model": "openrouter/openai/gpt-4o"

// 使用 OpenAI 直接連接
"model": "openai/gpt-4o"

// 使用 DeepSeek
"model": "deepseek/deepseek-chat"

// 使用 Anthropic Claude（透過 OpenRouter）
"model": "openrouter/anthropic/claude-opus-4-8"

// 使用 Google Gemini
"model": "openrouter/google/gemini-2.5-pro"

// 使用開源模型（成本較低）
"model": "openrouter/meta-llama/llama-4-maverick"
```

### IM 平台配置詳解

#### Telegram

1. 在 Telegram 中搜尋 [@BotFather](https://t.me/BotFather)
2. 發送 `/newbot` 指令
3. 依序輸入 Bot 名稱和使用者名稱
4. 取得 HTTP API Token（格式：`1234567890:AAF...`）
5. 將 Token 填入用戶配置的 `telegram_bot_token` 欄位

#### Slack

1. 前往 [api.slack.com/apps](https://api.slack.com/apps)
2. 點擊 "Create New App" → "From scratch"
3. 設定 Socket Mode（需要 App-Level Token）
4. 在 OAuth & Permissions 中加入 `chat:write`、`im:history`、`app_mentions:read` 權限
5. 安裝到 Workspace 後取得 Bot User OAuth Token
6. 將 Token 填入配置的 `slack_bot_token` 和 `slack_app_token` 欄位

#### Discord

1. 前往 [discord.com/developers](https://discord.com/developers)
2. 創建新應用 → 在 Bot 頁面創建 Bot
3. 設定必要的 Privileged Gateway Intents
4. 使用 OAuth2 URL 產生器邀請 Bot 到伺服器
5. 將 Bot Token 填入配置的 `discord_bot_token` 欄位

### Agent 系統提示詞設計

System Prompt 是定義 Agent 行為的核心。以下是推薦的設計原則：

**好的 System Prompt：**
```
你是一位名為「小幫手」的專業 AI 助手。你的職責是：
1. 以繁體中文清晰、友善地回答用戶問題
2. 當遇到不確定的問題時，坦承不知道而非編造答案
3. 在提供建議時，考慮用戶的具體情況並給出可操作的步驟
4. 保持積極和鼓勵的語氣
```

**應避免：**
- 過於簡短（如 "你是 AI 助手"）— 無法塑造獨特個性
- 過於冗長（超過 2000 字）— 消耗大量 Token 且效果遞減
- 包含敏感資訊（如真實 API Key）

### Bot 池管理

在生產環境中，Telegram Bot 數量有限（每個 Telegram 帳號約可創建 20 個 Bot）。建議策略：

1. **預先創建** — 使用多個 Telegram 帳號預先創建一批 Bot（例如 50 個）
2. **池化管理** — 將 Bot Token 存入 JSON 池檔案
3. **自動分配** — 部署腳本從池中取出空閒 Bot 分配給新用戶
4. **回收復用** — 用戶取消後，Bot 回到池中重用
5. **低水位告警** — 池中空閒 Bot 低於閾值時觸發通知

---

## 部署指南

### 完整部署流程

以下是從零開始部署一個用戶實例的完整步驟：

#### 步驟 1：設定 Railway 認證

```bash
# 從 Railway 控制台取得 API Token
# 前往: https://railway.app/account/tokens
export RAILWAY_TOKEN="ra-api-..."

# 驗證連接
railway whoami
# 預期輸出：顯示你的 Railway 帳號資訊
```

#### 步驟 2：準備 GitHub 儲存庫

確保 Railway 可以存取你的程式碼。Railway 支援直接從 GitHub 儲存庫部署：

```bash
# 確認 railway.toml 指向正確的 Dockerfile
cat railway.toml
# [build]
# builder = "DOCKERFILE"
# dockerfilePath = "./Dockerfile"
```

#### 步驟 3：建立用戶專案

```bash
./scripts/create-user-project.sh \
  --user-id user-001 \
  --github-repo "your-org/hermes-agent-railway"
```

此腳本會：
- 在 Railway 上創建一個新專案
- 連接到指定的 GitHub 儲存庫
- 觸發初始部署
- 掛載 `/data` 持久化磁碟區
- 輸出專案 ID 和部署狀態

#### 步驟 4：等待部署完成

```bash
# 監控部署狀態
railway status --project <project-id>

# 等待直到服務健康檢查通過
until curl -sf https://<service-url>.up.railway.app/health; do
  echo "等待部署完成..."
  sleep 10
done
echo "部署完成！"
```

#### 步驟 5：注入用戶配置

```bash
./scripts/inject-config.sh \
  --user-id user-001 \
  --config configs/user-001.json
```

此腳本會：
- 讀取用戶配置 JSON 檔案
- 將配置值轉換為環境變量
- 透過 Railway API 設定用戶專案的環境變量
- 觸發重新部署以套用新配置

#### 步驟 6：驗證部署結果

```bash
# 查看環境變量（敏感值會自動遮蔽）
railway variables list --project <project-id>

# 檢查服務日誌
railway logs --project <project-id> | tail -50

# 測試 IM Bot 功能
# 在 Telegram 中搜尋你的 Bot 並發送 /start
```

#### 步驟 7：連接 IM Bot

根據平台執行對應操作：

**Telegram：**
用戶在 Telegram 中搜尋 Bot 的使用者名稱，發送 `/start` 即可開始對話。

**Slack：**
用戶在 Slack 中安裝應用到其 Workspace，Bot 自動加入。

**Discord：**
Bot 加入伺服器後，用戶可透過 DM 或指定頻道與之互動。

### 使用完整部署腳本（一鍵部署）

如果你希望跳過手動步驟，可使用 `full-deploy.sh` 一鍵完成上述所有步驟：

```bash
./scripts/full-deploy.sh \
  --user-id user-001 \
  --config configs/user-001.json \
  --github-repo "your-org/hermes-agent-railway" \
  --wait-for-healthy \
  --notify-email "user@example.com"
```

選項說明：

| 選項 | 說明 |
|------|------|
| `--user-id` | 用戶唯一識別碼（必填） |
| `--config` | 用戶配置 JSON 檔案路徑（必填） |
| `--github-repo` | GitHub 儲存庫的 org/repo 格式 |
| `--wait-for-healthy` | 等待服務健康檢查通過後才結束 |
| `--notify-email` | 部署完成後發送通知至此郵箱 |
| `--skip-config` | 跳過配置注入步驟（稍後手動注入） |
| `--dry-run` | 僅輸出將執行的操作，不實際執行 |

### 批量部署

使用 `bulk-deploy.sh` 從 CSV 或 JSON 檔案批量部署多個用戶：

```bash
# 從 CSV 檔案批量部署
./scripts/bulk-deploy.sh --input users.csv

# 從 JSON 檔案批量部署
./scripts/bulk-deploy.sh --input users.json

# 限制並行數量（避免 Railway API 限流）
./scripts/bulk-deploy.sh --input users.csv --concurrency 3

# 預覽模式（不實際部署）
./scripts/bulk-deploy.sh --input users.csv --dry-run
```

**CSV 輸入檔案格式（users.csv）：**
```csv
user_id,email,agent_name,model,telegram_bot_token,llm_api_key
user-001,alice@example.com,小幫手,openrouter/openai/gpt-4o,123:ABC,sk-or-xxx
user-002,bob@example.com,助手,openrouter/anthropic/claude-sonnet,456:DEF,sk-or-xxx
```

### 回收用戶專案

當用戶取消訂閱時，使用 `deprovision.sh` 回收資源：

```bash
# 回收用戶專案（保留資料備份 7 天後自動刪除）
./scripts/deprovision.sh --user-id user-001

# 立即完全刪除（不保留資料）
./scripts/deprovision.sh --user-id user-001 --force

# 僅暫停服務（不刪除專案和資料）
./scripts/deprovision.sh --user-id user-001 --suspend
```

回收操作會：
1. 匯出用戶資料備份（對話歷史、配置）
2. 暫停 Railway 專案服務
3. 釋放 IM Bot 回資源池
4. 可選：在冷卻期後刪除 Railway 專案

---

## 腳本參考

### 腳本總覽

| 腳本 | 用途 |
|------|------|
| `scripts/common.sh` | 共用函式庫（日誌、Railway API 封裝、驗證工具） |
| `scripts/create-user-project.sh` | 在 Railway 上為用戶創建獨立專案 |
| `scripts/inject-config.sh` | 將用戶配置注入已部署的專案 |
| `scripts/full-deploy.sh` | 完整端到端部署流程 |
| `scripts/deprovision.sh` | 回收/刪除用戶專案和資源 |
| `scripts/bulk-deploy.sh` | 從檔案批量部署多個用戶 |
| `scripts/config-template.json` | 用戶配置 JSON 範本 |

### common.sh — 共用工具

所有腳本都會引用此檔案，提供以下功能：

```bash
# 在所有腳本中載入
source "$(dirname "$0")/common.sh"
```

提供的函式：

| 函式 | 說明 |
|------|------|
| `log_info "訊息"` | 輸出資訊日誌 |
| `log_warn "訊息"` | 輸出警告日誌 |
| `log_error "訊息"` | 輸出錯誤日誌 |
| `die "訊息"` | 輸出錯誤訊息並退出（exit 1） |
| `check_requirements` | 檢查必要環境變量和工具是否就緒 |
| `validate_config "路徑"` | 驗證用戶配置 JSON 檔案格式 |
| `railway_api "路徑" "方法" "資料"` | 封裝 Railway API 調用 |
| `sanitize_output "字串"` | 遮蔽輸出中的敏感資訊（Token、金鑰） |
| `generate_user_project_name "user-id"` | 根據用戶 ID 生成 Railway 專案名稱 |

### create-user-project.sh

在 Railway 上為單一用戶創建新的專案。

```bash
# 基本用法
./scripts/create-user-project.sh --user-id user-001

# 完整選項
./scripts/create-user-project.sh \
  --user-id user-001 \
  --github-repo "your-org/hermes-agent-railway" \
  --region "us-west1" \
  --plan "pro" \
  --volume-size-gb 10
```

**選項：**

| 選項 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `--user-id` | 是 | — | 用戶唯一識別碼 |
| `--github-repo` | 否 | `arjunkomath/hermes-agent-railway-template` | GitHub 儲存庫 |
| `--region` | 否 | `us-west1` | Railway 部署區域 |
| `--plan` | 否 | `hobby` | Railway 方案（hobby / pro） |
| `--volume-size-gb` | 否 | `5` | 持久化磁碟區大小（GB） |

**輸出：**
```
✓ 用戶專案已創建
  專案 ID: prj_abc123def456
  專案名稱: hermes-user-001
  服務 URL: https://hermes-user-001.up.railway.app
  狀態: 部署中...
```

### inject-config.sh

將用戶配置注入到已部署的 Railway 專案中。

```bash
# 基本用法
./scripts/inject-config.sh --user-id user-001 --config configs/user-001.json

# 完整選項
./scripts/inject-config.sh \
  --user-id user-001 \
  --config configs/user-001.json \
  --restart \
  --wait
```

**選項：**

| 選項 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `--user-id` | 是 | — | 用戶唯一識別碼 |
| `--config` | 是 | — | 配置 JSON 檔案路徑 |
| `--restart` | 否 | false | 注入後自動重啟服務 |
| `--wait` | 否 | false | 等待重啟完成並確認健康 |

**注入的環境變量：**
腳本會將 JSON 配置轉換為 Railway 環境變量：

| JSON 欄位 | 環境變量 |
|-----------|---------|
| `agent_name` | `HERMES_DEFAULT_AGENT_NAME` |
| `agent_system_prompt` | `HERMES_DEFAULT_AGENT_SYSTEM_PROMPT` |
| `model` | `HERMES_DEFAULT_AGENT_MODEL` |
| `tools` | `HERMES_DEFAULT_AGENT_TOOLS` |
| `telegram_bot_token` | `TELEGRAM_BOT_TOKEN` |
| `slack_bot_token` | `SLACK_BOT_TOKEN` |
| `slack_app_token` | `SLACK_APP_TOKEN` |
| `discord_bot_token` | `DISCORD_BOT_TOKEN` |
| `llm_api_key` | `OPENROUTER_API_KEY` |

### full-deploy.sh

完整的端到端部署腳本，整合上述所有步驟。

```bash
# 一鍵部署
./scripts/full-deploy.sh --user-id user-001 --config configs/user-001.json

# 完整選項
./scripts/full-deploy.sh \
  --user-id user-001 \
  --config configs/user-001.json \
  --github-repo "your-org/hermes-agent-railway" \
  --region "us-west1" \
  --plan "pro" \
  --volume-size-gb 10 \
  --wait-for-healthy \
  --notify-email "user@example.com" \
  --skip-config \
  --dry-run
```

**執行流程：**

```
1. 檢查環境（Railway Token、必要工具）
2. 驗證用戶配置 JSON 格式
3. 建立 Railway 專案（create-user-project.sh）
4. 等待部署完成
5. 注入用戶配置（inject-config.sh）
6. 驗證服務健康狀態
7. 可選：發送歡迎通知
8. 輸出部署摘要
```

### deprovision.sh

回收用戶的 Railway 專案和相關資源。

```bash
# 回收用戶專案（預設保留備份 7 天）
./scripts/deprovision.sh --user-id user-001

# 立即完全刪除
./scripts/deprovision.sh --user-id user-001 --force

# 僅暫停（可恢復）
./scripts/deprovision.sh --user-id user-001 --suspend

# 批量回收
./scripts/deprovision.sh --users-file users-to-delete.txt
```

**安全性機制：**
- 預設需要二次確認（透過互動式提示）
- `--force` 模式下需輸入用戶 ID 確認
- 刪除前自動匯出對話歷史備份
- 操作記錄寫入審計日誌

### bulk-deploy.sh

從 CSV 或 JSON 檔案批量部署多個用戶。

```bash
# CSV 輸入
./scripts/bulk-deploy.sh --input users.csv --concurrency 5

# JSON 輸入
./scripts/bulk-deploy.sh --input users.json

# 預覽模式
./scripts/bulk-deploy.sh --input users.csv --dry-run

# 從第 N 行開始（續傳功能）
./scripts/bulk-deploy.sh --input users.csv --skip 10

# 僅處理特定行
./scripts/bulk-deploy.sh --input users.csv --start 5 --end 20
```

**輸出格式（即時）：**
```
[1/50] user-001: ✓ 已部署 (prj_abc123) — https://hermes-user-001.up.railway.app
[2/50] user-002: ✓ 已部署 (prj_def456) — https://hermes-user-002.up.railway.app
[3/50] user-003: ✗ 失敗 — Railway API 限流，將在 30 秒後重試...
[4/50] user-004: ✓ 已部署 (prj_ghi789) — https://hermes-user-004.up.railway.app
...
完成：成功 48，失敗 2
失敗詳情已寫入 bulk-deploy-errors-20260531-143022.log
```

---

## 環境變量參考

### 完整環境變量列表

#### 平台級（所有實例通用）

| 變量 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `PORT` | 否 | `8080` | Web 伺服器監聽埠號 |
| `HOME` | 否 | `/data` | 應用程式根目錄 |
| `HERMES_HOME` | 否 | `/data/.hermes` | Hermes 資料根目錄 |
| `PYTHONUNBUFFERED` | 否 | `1` | Python 無緩衝輸出（日誌即時） |
| `ADMIN_PASSWORD` | **是** | — | Web 儀表板管理員密碼（無預設值，必須設定） |

#### LLM Provider API 金鑰

| 變量 | 必填 | 說明 |
|------|------|------|
| `OPENROUTER_API_KEY` | **是**（建議） | OpenRouter API 金鑰，可存取數百種模型 |
| `OPENAI_API_KEY` | 否 | OpenAI 直接連接 API 金鑰 |
| `DEEPSEEK_API_KEY` | 否 | DeepSeek API 金鑰 |
| `ANTHROPIC_API_KEY` | 否 | Anthropic Claude API 金鑰 |
| `GOOGLE_API_KEY` | 否 | Google Gemini API 金鑰 |
| `GROQ_API_KEY` | 否 | Groq 快速推理 API 金鑰 |
| `XAI_API_KEY` | 否 | xAI (Grok) API 金鑰 |
| `TOGETHER_API_KEY` | 否 | Together AI 開源模型 API 金鑰 |

#### Agent 配置

| 變量 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `HERMES_DEFAULT_AGENT_NAME` | 否 | `Hermes Assistant` | 默認 Agent 的顯示名稱 |
| `HERMES_DEFAULT_AGENT_SYSTEM_PROMPT` | 是 | `"You are a helpful AI assistant powered by Hermes."` | 默認 Agent 的系統提示詞 |
| `HERMES_DEFAULT_AGENT_MODEL` | 否 | `openrouter/openai/gpt-4o` | 默認 Agent 使用的 LLM 模型 |
| `HERMES_DEFAULT_AGENT_TOOLS` | 否 | `""`（空，全部可用） | 默認 Agent 的可用工具（逗號分隔） |

#### IM Gateway 配置

| 變量 | 必填 | 說明 |
|------|------|------|
| `TELEGRAM_BOT_TOKEN` | 否 | Telegram Bot HTTP API Token |
| `SLACK_BOT_TOKEN` | 否 | Slack Bot User OAuth Token |
| `SLACK_APP_TOKEN` | 否 | Slack App-Level Token（Socket Mode） |
| `DISCORD_BOT_TOKEN` | 否 | Discord Bot Token |
| `WHATSAPP_TOKEN` | 否 | WhatsApp Business API Token |
| `MSTEAMS_CLIENT_ID` | 否 | Microsoft Teams Azure AD Client ID |
| `MATRIX_HOMESERVER` | 否 | Matrix Homeserver URL（自託管或公有） |
| `TWITTER_USERNAME` | 否 | Twitter/X 使用者名稱（DM 模式） |

#### Token Proxy / 計費

| 變量 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `TOKEN_QUOTA_MONTHLY` | 否 | `1000000` | 月度 Token 配額上限 |
| `TOKEN_QUOTA_WARN_50` | 否 | `true` | 用達 50% 時發出提醒 |
| `TOKEN_QUOTA_WARN_80` | 否 | `true` | 用達 80% 時發出提醒 |
| `TOKEN_QUOTA_WARN_95` | 否 | `true` | 用達 95% 時發出提醒 |

#### Slack 通知（可選）

| 變量 | 必填 | 預設值 | 說明 |
|------|------|--------|------|
| `SLACK_NOTIFY_WEBHOOK` | 否 | — | 運營通知 Slack Webhook URL |
| `DISCORD_NOTIFY_WEBHOOK` | 否 | — | 運營通知 Discord Webhook URL |

---

## Web 管理後台

每個 Hermes Agent 實例內建一個基於 Starlette + Uvicorn 的輕量級 Web 管理後台。

### 功能概覽

| 功能 | 說明 |
|------|------|
| **Gateway 狀態面板** | 查看所有 IM Gateway 的運行狀態（線上/離線/錯誤） |
| **Gateway 控制** | 啟動、停止、重啟個別 IM Gateway |
| **配置管理** | 查看和修改 Agent 系統設定 |
| **日誌檢視器** | 即時查看和搜尋應用程式日誌 |
| **記憶體統計** | 查看持久化記憶容量、對話歷史數量 |
| **IM 配對管理** | 管理用戶與 IM Bot 的配對關係 |
| **健康檢查** | `GET /health` 端點供 Railway 和外部監控使用 |

### API 端點

| 路由 | 方法 | 說明 | 認證 |
|------|------|------|------|
| `/` | GET | Web 管理儀表板主頁 | 密碼 |
| `/health` | GET | 健康檢查（Railway 用） | 無 |
| `/api/status` | GET | 完整狀態 JSON | 密碼 |
| `/api/gateways` | GET | Gateway 列表和狀態 | 密碼 |
| `/api/gateways/{name}/start` | POST | 啟動指定 Gateway | 密碼 |
| `/api/gateways/{name}/stop` | POST | 停止指定 Gateway | 密碼 |
| `/api/gateways/{name}/restart` | POST | 重啟指定 Gateway | 密碼 |
| `/api/config` | GET | 讀取當前配置 | 密碼 |
| `/api/config` | PUT | 更新配置 | 密碼 |
| `/api/logs` | GET | 查詢日誌（支援 `?lines=100&filter=ERROR`） | 密碼 |
| `/api/memory/stats` | GET | 記憶體使用統計 | 密碼 |
| `/api/pairings` | GET | IM 配對列表 | 密碼 |

### 訪問後台

```
https://<your-service-url>.up.railway.app/
```

使用 `ADMIN_PASSWORD` 環境變量設定的密碼登入。

### 安全建議

- **變更預設密碼** — 生產環境必須設定強密碼
- **啟用 HTTPS** — Railway 預設提供 TLS 終端
- **限制訪問 IP** — 可選：透過 Railway 網路策略限制來源 IP
- **定期更換密碼** — 建議每 90 天更換管理員密碼

---

## 日常維護

### 檢查用戶實例健康狀態

```bash
# 檢查單一用戶
railway status --project prj_abc123def456

# 檢查所有用戶（從專案清單）
for project in $(railway project list --json | jq -r '.[].id'); do
  status=$(railway status --project "$project" --json | jq -r '.status')
  echo "$project: $status"
done
```

### 監控資源用量

```bash
# 查看 Railway 專案資源用量
railway metrics --project prj_abc123def456

# 查看特定用戶的磁碟使用量
curl -s https://hermes-user-001.up.railway.app/api/memory/stats \
  -H "Authorization: Bearer ${ADMIN_PASSWORD}"
```

### 更新 Hermes Agent

當 Hermes Agent 有新版本發布時：

```bash
# 步驟 1：更新 requirements.txt 中的 hermes-agent 版本
# hermes-agent>=1.2.0  →  hermes-agent>=1.3.0

# 步驟 2：推送更新到 GitHub
git add requirements.txt
git commit -m "升級 hermes-agent 至 v1.3.0"
git push

# 步驟 3：Railway 自動重新部署（若啟用自動部署）
# 或手動觸發重新部署：
railway redeploy --project prj_abc123def456
```

### 備份用戶資料

```bash
# 匯出單一用戶的對話資料
./scripts/deprovision.sh --user-id user-001 --export-only --output ./backups/

# 輸出結構：
# ./backups/user-001/
#   ├── sessions.json       # 對話歷史
#   ├── config.json         # Agent 配置
#   ├── pairing.json        # IM 配對資訊
#   └── export-20260531.log # 匯出操作日誌
```

### 擴展 Bot 池

```bash
# 當 Bot 池低於安全水位時，批量新增 Telegram Bot
# 注意：此操作需要手動在 Telegram 中創建 Bot

# 檢查 Bot 池狀態
./scripts/manage-bot-pool.sh --status

# 新增 Bot 到池中
./scripts/manage-bot-pool.sh --add \
  --token "1234567890:AA..." \
  --bot-name "hermes_bot_pool_023"

# 從 CSV 檔案批量匯入
./scripts/manage-bot-pool.sh --import bot-tokens.csv
```

### 定期維護檢查清單

| 頻率 | 任務 | 指令 |
|------|------|------|
| 每日 | 檢查所有實例健康狀態 | `railway status --all` |
| 每日 | 檢查 Bot 池水位 | `./scripts/manage-bot-pool.sh --status` |
| 每週 | 匯出所有用戶備份 | `./scripts/bulk-backup.sh` |
| 每週 | 檢查 Railway 帳單和成本 | Railway 控制台 → Billing |
| 每月 | 審查安全日誌 | 檢查 Web 儀表板存取記錄 |
| 每月 | 更新依賴套件 | `pip list --outdated` |
| 每季 | 更換管理員密碼 | 更新 `ADMIN_PASSWORD` 環境變量 |

---

## 故障排除

### 常見問題與解決方案

#### 1. Gateway 無法啟動

**症狀：** Web 儀表板顯示 Gateway 狀態為 "離線" 或 "錯誤"

**可能原因與解決：**

```bash
# 檢查環境變量是否正確設定
railway variables list --project <project-id>

# 常見問題：Bot Token 格式錯誤
# Telegram Token 格式應為：1234567890:AAF...（數字:英數字元）
# 確認無多餘空格或換行符

# 檢查 Gateway 日誌
railway logs --project <project-id> | grep -i "gateway\|error"

# 手動重啟 Gateway
curl -X POST https://<service-url>.up.railway.app/api/gateways/telegram/restart \
  -H "Authorization: Bearer ${ADMIN_PASSWORD}"
```

#### 2. IM Bot 不回應

**症狀：** Bot 顯示為線上但發送訊息後無回應

**可能原因：**

| 原因 | 解決方案 |
|------|---------|
| LLM API 金鑰無效 | 檢查 `OPENROUTER_API_KEY` 是否正確且未過期 |
| Token 配額耗盡 | 檢查 Web 儀表板 → 記憶體統計 → Token 用量 |
| IM Bot Token 已撤銷 | 從 BotFather 重新生成 Token 並更新配置 |
| Webhook 未正確設定 | Telegram Bot 需要正確的 Webhook URL；檢查後台日誌 |

```bash
# 檢查 LLM API 連接
curl -s https://openrouter.ai/api/v1/auth/key \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}"

# 測試 Bot Token 有效性（Telegram）
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
```

#### 3. 記憶體/資料持久化問題

**症狀：** 重啟後對話歷史或配置丟失

**可能原因：**

- `/data` 磁碟區未正確掛載
- 磁碟區空間不足
- SQLite 資料庫損壞

```bash
# 檢查磁碟區掛載狀態
railway volumes list --project <project-id>

# SSH 進入容器檢查檔案
railway shell --project <project-id>
# 在容器中：ls -la /data/
# 在容器中：df -h /data

# 修復 SQLite 資料庫
railway shell --project <project-id>
# 在容器中：sqlite3 /data/.hermes/sessions/honcho.db "PRAGMA integrity_check;"
```

#### 4. 部署超時

**症狀：** Railway 部署長時間處於 "Building" 或 "Deploying" 狀態

```bash
# 檢查建置日誌
railway logs --project <project-id> --builder

# 常見原因：Docker 建置過程中依賴安裝失敗
# 解決：檢查 requirements.txt 中的依賴版本是否相容

# 增加部署超時時間（在 railway.toml 中設定，預設 20 分鐘）
# Railway 通常會在 20 分鐘後超時，檢查是否有大型依賴（如 PyTorch）
```

#### 5. 磁碟區掛載問題

**症狀：** 容器啟動後 `/data` 目錄為空或權限錯誤

```bash
# 確認 Railway 專案已建立磁碟區
railway volumes list --project <project-id>

# 如果磁碟區不存在，手動建立
railway volume add \
  --project <project-id> \
  --service <service-id> \
  --mount-path /data \
  --size-gb 5
```

#### 6. 環境變量未生效

**症狀：** 修改環境變量後配置沒有更新

```bash
# Railway 環境變量變更後需要重新部署
railway redeploy --project <project-id>

# 確認當前環境變量
railway variables list --project <project-id>

# 進入容器確認執行時期的環境變量
railway shell --project <project-id>
# 在容器中：env | grep HERMES
```

### 診斷工具

```bash
# 快速診斷腳本
./scripts/diagnose.sh --user-id user-001
# 輸出：
# ✓ Railway 連接正常
# ✓ 專案存在 (prj_abc123)
# ✓ 服務運行中
# ✓ 健康檢查通過 (200 OK)
# ✓ 磁碟區已掛載 (/data: 3.2 GB / 5 GB)
# ⚠ Telegram Gateway: 離線 (Token 無效)
# ✓ 磁碟空間正常 (64% 可用)
```

---

## 安全注意事項

### 金鑰管理

**絕對不應該做的事：**
- ❌ 將 API 金鑰寫入程式碼或提交到 Git
- ❌ 在日誌中輸出明文金鑰
- ❌ 透過不安全的渠道（電子郵件、未加密的即時通訊）傳輸金鑰

**應該做的事：**
- ✓ 所有金鑰通過 Railway 環境變量注入（Railway 加密儲存）
- ✓ 使用 `.env.example` 作為環境變量參考，實際值在 `.env` 中（不提交到 Git）
- ✓ 日誌輸出前使用 `sanitize_output()` 函式遮蔽敏感資訊
- ✓ 定期輪換 API 金鑰

### .gitignore 建議

```gitignore
# 環境變量檔案
.env

# 用戶配置檔案（含金鑰）
configs/*.json
!configs/*.example.json

# 備份檔案
backups/

# Python
__pycache__/
*.pyc

# IDE
.vscode/
.idea/

# macOS
.DS_Store
```

### ADMIN_PASSWORD 管理

- 設定強密碼（至少 16 字元，含大小寫字母、數字和特殊符號）
- 不要在腳本中以明文傳遞密碼（使用環境變量或密碼管理器）
- 不同用戶實例應使用不同的管理密碼

```bash
# 使用密碼產生器
ADMIN_PASSWORD=$(openssl rand -base64 24)

# 或使用 1Password CLI
ADMIN_PASSWORD=$(op item get "Hermes Admin" --fields password)
```

### IM Bot Token 安全

- Telegram Bot Token 授予對 Bot 的完全控制權——對待它如同密碼
- 如果 Bot Token 洩漏，立即透過 [@BotFather](https://t.me/BotFather) 撤銷並重新生成
- Slack Bot Token 權限應遵循最小權限原則（僅授予必要的 OAuth Scope）

### API 金鑰靜態加密

在生產環境中，建議使用 Railway 的 Secret 功能儲存敏感環境變量。Railway 對所有環境變量進行靜態加密（AES-256），並在傳輸過程中使用 TLS 保護。

### 網路隔離

- 每位用戶的 Railway 專案在網路層面天然隔離
- 容器之間無法直接通訊（除非透過公開 URL）
- Web 儀表板通過密碼認證保護
- 建議：對管理 API 端點實施 IP 白名單（透過 Railway 網路策略或應用層中介軟體）

### 資料隱私

- 用戶對話歷史僅儲存在其專屬的 `/data` 磁碟區中
- 取消訂閱時，系統自動刪除用戶資料（冷卻期內可恢復）
- 用戶資料傳輸透過 Railway 的 TLS 終端加密
- 符合 GDPR 資料刪除要求（用戶可隨時申請完整刪除）

---

## 常見問題

### 一般問題

**Q：為什麼選擇 Railway 而不是 AWS/GCP/Azure？**

A：Railway 提供極簡的部署體驗，無需管理 Kubernetes 或基礎設施。對於「一用戶一實例」的架構，Railway 的專案隔離模型天然匹配。同時 Railway 的自動擴展、健康檢查和持久化磁碟區減少了大量 Ops 工作。

**Q：每個 Railway 專案的成本是多少？**

A：截至 2026 年 5 月，Railway Hobby 方案的基礎費用約為 $5/月/專案（含 512MB RAM + 1 vCPU + 5GB 磁碟）。Pro 方案從 $20/月起。具體定價請參閱 [Railway 定價頁面](https://railway.app/pricing)。

**Q：系統能支援多少用戶？**

A：理論上沒有限制。每個用戶是一個獨立專案，Railway 的架構支援大量專案並行運行。實際限制取決於你的 Railway 帳號配額和預算。建議從 10-50 個用戶開始，確認成本模型後再擴展。

**Q：可以讓用戶自帶 API Key 嗎？**

A：可以。在用戶配置中將 `llm_api_key` 設為用戶提供的金鑰即可。該金鑰會作為環境變量注入到其專屬實例中，不會與其他用戶共用。

### 部署與配置

**Q：部署一個新用戶需要多長時間？**

A：首次部署約 3-5 分鐘（Docker 建置 + Railway 部署）。後續重新部署（僅變更環境變量）約 30-60 秒。

**Q：如何更新所有用戶的 Hermes Agent 版本？**

A：更新 GitHub 儲存庫中的 `requirements.txt` 或 Dockerfile，Railway 會根據設定自動重新部署。若未啟用自動部署，可使用批次腳本觸發所有專案的重新部署：

```bash
# 批次重新部署所有用戶
railway project list --json | jq -r '.[].id' | while read project; do
  railway redeploy --project "$project" &
done
wait
```

**Q：如何為特定用戶設定不同的 LLM 模型？**

A：在用戶配置 JSON 中設定 `model` 欄位，或直接設定 `HERMES_DEFAULT_AGENT_MODEL` 環境變量：

```bash
railway variables set HERMES_DEFAULT_AGENT_MODEL="openrouter/anthropic/claude-opus-4-8" \
  --project prj_abc123
```

**Q：如何新增更多 IM 平台支援？**

A：在用戶配置中新增對應平台的 Bot Token 環境變量，並確保 Dockerfile 中已安裝對應的 Gateway 依賴。Hermes Agent 的 IM Gateway 採用模組化設計，新增平台通常只需設定環境變量即可。

### Token 與計費

**Q：Token 配額如何計算？**

A：系統追蹤所有 LLM 請求的輸入和輸出 Token。計數基於 LLM Provider 回傳的實際 Token 用量，而非估算值。月度配額在每月結算日自動重置。

**Q：用戶配額耗盡後會發生什麼？**

A：系統會拒絕新的 LLM 請求並向用戶顯示友善的提示訊息，引導其進行充值。對話歷史和配置不會受到影響。

**Q：如何監控每個用戶的實際成本？**

A：Railway 的專案級別帳單可以顯示每個專案的成本。你可以使用 Railway API 匯總所有專案的成本：

```bash
# 查詢 Railway 帳號總成本
railway billing usage --current-month
```

### 技術問題

**Q：資料儲存在哪裡？資料安全嗎？**

A：所有用戶資料儲存在 Railway 專案的持久化磁碟區（`/data`）中。資料在 Railway 的基礎設施上進行靜態加密，傳輸過程使用 TLS。每位用戶的資料完全隔離。

**Q：如果 Railway 服務中斷怎麼辦？**

A：Railway 具有高可用性架構，提供自動故障轉移。用戶的持久化資料儲存在磁碟區中，不會因容器重啟而丟失。建議設定監控告警以即時獲知中斷情況。

**Q：如何進行本地開發和測試？**

A：使用 `docker compose up` 在本機啟動完整環境。`.env.example` 檔案提供了本地開發所需的環境變量參考。注意：本地開發時 IM Gateway 需要實際的 Bot Token 才能完全測試。

```bash
# 本地開發
cp .env.example .env
# 編輯 .env，至少填入一個 LLM API Key
docker compose up --build
```

**Q：系統支援哪些 LLM 模型？**

A：透過 OpenRouter，系統支援 200+ 種模型，包括 OpenAI GPT-4、Anthropic Claude、Google Gemini、Meta Llama、DeepSeek 等。你也可以透過直接 API 連接使用 OpenAI、DeepSeek、Anthropic 等 Provider 的原生模型。

---

## 專案結構

```
hermes-auto-railway/
├── Dockerfile                  # 多階段建置：Python + Node.js + Hermes Agent
├── railway.toml                # Railway 專案配置（構建、部署、健康檢查）
├── start.sh                    # 啟動腳本（初始化目錄、產生配置、啟動伺服器）
├── server.py                   # Web 儀表板 + Hermes Gateway 管理器（Starlette/Uvicorn）
├── requirements.txt            # Python 依賴套件
├── docker-compose.yml          # 本地開發環境
├── .env.example                # 環境變量參考範本
├── templates/
│   └── index.html              # Web 管理儀表板前端頁面
├── scripts/
│   ├── common.sh               # 共用 Shell 函式庫
│   ├── create-user-project.sh  # 建立 Railway 用戶專案
│   ├── inject-config.sh        # 注入用戶配置到專案
│   ├── full-deploy.sh          # 完整端到端部署流程
│   ├── deprovision.sh          # 回收/刪除用戶專案
│   ├── bulk-deploy.sh          # 從檔案批量部署多用戶
│   └── config-template.json    # 用戶配置 JSON 範本
└── data/
    └── hermes-saas-prd.md      # 產品需求文件（PRD）
```

---

## 技術棧

| 層級 | 技術 | 用途 |
|------|------|------|
| **運行環境** | Docker | 容器化部署 |
| **雲平台** | Railway.app | PaaS 託管、磁碟區、健康檢查 |
| **AI 引擎** | Hermes Agent | 核心對話引擎、工具調用、IM Gateway |
| **Web 框架** | Starlette + Uvicorn | 管理儀表板和 API |
| **記憶持久化** | Honcho (SQLite) | 對話歷史和鍵值儲存 |
| **LLM 路由** | OpenRouter | 統一 API 端點，多模型存取 |
| **腳本語言** | Bash + Python | 自動化部署和管理 |
| **前端** | HTML + CSS + JavaScript | Web 儀表板 |
| **Node.js** | Node 24 | 部分 Gateway 運行時（Slack、Discord） |

---

## 授權

本專案採用 [MIT License](https://opensource.org/licenses/MIT)。

本專案基於 [Hermes Agent](https://github.com/nousresearch/hermes-agent)（Nous Research）和 [hermes-agent-railway-template](https://github.com/arjunkomath/hermes-agent-railway-template)（Arjun Komath）構建。

---

## 貢獻

歡迎提交 Issue 和 Pull Request。重大變更請先開 Issue 討論你計畫的修改。

---

<p align="center">
  <sub>使用 ❤️ 和 Hermes Agent 構建 | Powered by Railway</sub>
</p>
