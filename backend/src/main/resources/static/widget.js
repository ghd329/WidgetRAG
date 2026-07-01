const currentScript = document.currentScript;

const WIDGET_CLIENT_CODE =
    currentScript?.dataset.clientCode || "";

const WIDGET_BACKEND_BASE =
    currentScript?.dataset.backendBase || "http://127.0.0.1:8080";

// const WIDGET_CLIENT_CODE = "shop_56d80286";

(function () {
    const style = document.createElement("style");
    style.innerHTML = `
        #chatbotBubble {
            position: fixed;
            right: 34px;
            bottom: 34px;
            width: 86px;
            height: 86px;
            border-radius: 28px;
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            color: white;
            display: flex;
            align-items: center;
            justify-content: center;
            cursor: pointer;
            box-shadow: 0 18px 45px rgba(79,70,229,.38);
            z-index: 9999;
            transition: .25s;
        }

        #chatbotBubble:hover {
            transform: translateY(-5px) scale(1.04);
        }

        #chatbotTooltip{
            position:fixed;
            right:125px;
            bottom:52px;

            background:white;
            border-radius:20px;
            padding:14px 18px;

            box-shadow:0 10px 30px rgba(0,0,0,.18);

            display:flex;
            align-items:center;
            gap:12px;

            z-index:9999;

            animation:tooltipUp .5s;
        }

        #chatbotTooltip::after{
            content:"";
            position:absolute;
            right:-8px;
            bottom:22px;

            width:16px;
            height:16px;

            background:white;

            transform:rotate(45deg);
        }

        .tooltip-close{
            cursor:pointer;
            color:#999;
            font-size:22px;
            margin-left:5px;
        }

        .tooltip-title{
            font-weight:700;
            font-size:18px;
        }

        .tooltip-sub{
            color:#8a8a8a;
            font-size:14px;
            margin-top:3px;
        }

        .tooltip-dot{
            color:#22c55e;
        }

        @keyframes tooltipUp{
            from{
                opacity:0;
                transform:translateY(20px);
            }
            to{
                opacity:1;
                transform:translateY(0);
            }
        }

        .bot-face {
            width: 54px;
            height: 42px;
            background: white;
            border-radius: 18px;
            position: relative;
            box-shadow: inset 0 -4px 0 rgba(0,0,0,.08);
        }

        .bot-face::before,
        .bot-face::after {
            content: "";
            position: absolute;
            top: 16px;
            width: 7px;
            height: 7px;
            background: #4f46e5;
            border-radius: 50%;
        }

        .bot-face::before { left: 15px; }
        .bot-face::after { right: 15px; }

        .bot-smile {
            position: absolute;
            left: 20px;
            bottom: 9px;
            width: 14px;
            height: 7px;
            border-bottom: 3px solid #4f46e5;
            border-radius: 0 0 20px 20px;
        }

        .bot-antenna {
            position: absolute;
            top: 13px;
            width: 2px;
            height: 12px;
            background: white;
        }

        .bot-antenna::before {
            content: "";
            position: absolute;
            left: -5px;
            top: -8px;
            width: 12px;
            height: 12px;
            background: #facc15;
            border-radius: 50%;
        }

        #chatbotWidget {
            position: fixed;
            right: 34px;
            bottom: 134px;
            width: 500px;
            height: 760px;
            background: white;
            border-radius: 30px;
            box-shadow: 0 24px 70px rgba(15,23,42,.24);
            display: none;
            flex-direction: column;
            overflow: hidden;
            z-index: 9999;
            font-family: "Pretendard", sans-serif;
            border: 1px solid #ede9fe;
        }

        .chatbot-header {
            padding: 30px;
            background: linear-gradient(135deg, #f5f3ff, #eef2ff);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .chatbot-title {
            display: flex;
            align-items: center;
            gap: 14px;
        }

        .chatbot-mini-icon {
            width: 68px;
            height: 68px;
            border-radius: 18px;
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            display: flex;
            align-items: center;
            justify-content: center;
            box-shadow: 0 10px 22px rgba(79,70,229,.24);
        }

        .mini-face {
            width: 32px;
            height: 25px;
            background: white;
            border-radius: 11px;
            position: relative;
        }

        .mini-face::before,
        .mini-face::after {
            content: "";
            position: absolute;
            top: 10px;
            width: 4px;
            height: 4px;
            background: #4f46e5;
            border-radius: 50%;
        }

        .mini-face::before { left: 9px; }
        .mini-face::after { right: 9px; }

        .chatbot-header strong {
            display: block;
            color: #1e1b4b;
            font-size: 20px;
            margin-bottom: 5px;
        }

        .chatbot-header p {
            font-size: 13px;
            color: #6b7280;
        }

        .chatbot-header button {
            border: none;
            background: white;
            color: #4f46e5;
            width: 38px;
            height: 38px;
            border-radius: 50%;
            font-size: 24px;
            cursor: pointer;
            box-shadow: 0 6px 16px rgba(0,0,0,.08);
        }

        .chatbot-messages {
            flex: 1;
            padding: 28px;
            overflow-y: auto;
            background: #fbfbff;
        }

        .bot-message,
        .user-message {
            max-width: 82%;
            padding: 14px 16px;
            border-radius: 18px;
            margin-bottom: 14px;
            line-height: 1.55;
            font-size: 14px;
            white-space: pre-line;
        }

        .bot-message {
            background: white;
            color: #111827;
            border: 1px solid #ede9fe;
            box-shadow: 0 6px 18px rgba(79,70,229,.07);
        }

        .user-message {
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            color: white;
            margin-left: auto;
            box-shadow: 0 8px 18px rgba(79,70,229,.25);
        }

        .quick-buttons {
            display: flex;
            flex-direction: column;
            gap: 10px;
            margin-top: 14px;
        }

        .quick-buttons button {
            border: 1px solid #ddd6fe;
            background: white;
            color: #3730a3;
            padding: 13px;
            border-radius: 16px;
            font-weight: 800;
            cursor: pointer;
            text-align: left;
        }

        .quick-buttons button:hover {
            background: #f5f3ff;
        }

        .chatbot-input {
            display: flex;
            gap: 10px;
            padding: 16px;
            border-top: 1px solid #ede9fe;
            background: white;
        }

        .chatbot-input input {
            flex: 1;
            border: 1px solid #ddd6fe;
            border-radius: 18px;
            padding: 16px;
            outline: none;
            font-size: 16px;
        }

        .chatbot-input button {
            width: 62px;
            border: none;
            border-radius: 18px;
            background: linear-gradient(135deg, #4f46e5, #7c3aed);
            color: white;
            font-size: 24px;
            font-weight: 900;
            cursor: pointer;
        }

        /* 상품 추천 카드 */
        .product-cards {
            display: flex;
            flex-direction: column;
            gap: 10px;
            margin-bottom: 14px;
        }

        .product-card {
            display: flex;
            align-items: center;
            gap: 12px;
            background: white;
            border: 1px solid #ede9fe;
            border-radius: 16px;
            padding: 12px;
            text-decoration: none;
            color: inherit;
            box-shadow: 0 6px 18px rgba(79,70,229,.07);
            transition: box-shadow .15s, transform .15s;
        }

        a.product-card:hover {
            box-shadow: 0 10px 26px rgba(79,70,229,.18);
            transform: translateY(-1px);
            cursor: pointer;
        }

        .product-card-img img {
            width: 60px;
            height: 60px;
            object-fit: cover;
            border-radius: 12px;
            background: #f3f4f6;
            flex-shrink: 0;
        }

        .product-card-info {
            min-width: 0;
        }

        .product-card-name {
            font-size: 13.5px;
            font-weight: 700;
            color: #1e1b4b;
            margin: 0 0 4px;
            overflow: hidden;
            text-overflow: ellipsis;
            white-space: nowrap;
        }

        .product-card-price {
            font-size: 13.5px;
            font-weight: 800;
            color: #4f46e5;
            margin: 0;
        }
    `;
    document.head.appendChild(style);

    const widget = document.createElement("div");
    widget.innerHTML = `

            <div id="chatbotTooltip">

            <div>

                <div class="tooltip-title">
                    궁금한 건 채팅으로 문의하세요
                </div>

                <div class="tooltip-sub">
                    <span class="tooltip-dot">●</span>
                    몇 분 내 답변 받을 수 있어요
                </div>

            </div>

            <div class="tooltip-close" id="tooltipClose">
                ×
            </div>

        </div>
        <div id="chatbotBubble">
            <div class="bot-antenna"></div>
            <div class="bot-face">
                <div class="bot-smile"></div>
            </div>
        </div>

        <div id="chatbotWidget">
            <div class="chatbot-header">
                <div class="chatbot-title">
                    <div class="chatbot-mini-icon">
                        <div class="mini-face"></div>
                    </div>
                    <div>
                        <strong>AI 쇼핑 도우미 ✨</strong>
                        <p>상품 데이터를 기반으로 추천해드려요</p>
                    </div>
                </div>
                <button id="chatbotCloseBtn">×</button>
            </div>

            <div id="chatbotMessages" class="chatbot-messages">
                <div class="bot-message">
                    안녕하세요! 👋
                    원하는 상품 조건을 말해주시면 추천해드릴게요.
                </div>

                <div class="quick-buttons">
                    <button data-question="3만원 이하 상품 추천해줘">💰 3만원 이하 상품 추천해줘</button>
                    <button data-question="여름에 입기 좋은 옷 추천해줘">☀️ 여름에 입기 좋은 옷 추천해줘</button>
                    <button data-question="친구 생일 선물 추천해줘">🎁 친구 생일 선물 추천해줘</button>
                    <button data-question="지금 인기 있는 상품 추천해줘">🔥 인기 상품 추천해줘</button>
                </div>
            </div>

            <div class="chatbot-input">
                <input id="chatbotInput" placeholder="궁금한 상품을 물어보세요">
                <button id="chatbotSendBtn">➤</button>
            </div>
        </div>
    `;

    document.body.appendChild(widget);

    const bubble = document.getElementById("chatbotBubble");
    const chatbot = document.getElementById("chatbotWidget");
    const closeBtn = document.getElementById("chatbotCloseBtn");
    const sendBtn = document.getElementById("chatbotSendBtn");
    const input = document.getElementById("chatbotInput");

    const tooltip = document.getElementById("chatbotTooltip");
    const tooltipClose = document.getElementById("tooltipClose");

    bubble.onclick = function () {
        chatbot.style.display = "flex";
        bubble.style.display = "none";
        tooltip.style.display = "none";
    };

    tooltip.onclick = function () {
        chatbot.style.display = "flex";
        bubble.style.display = "none";
        tooltip.style.display = "none";
    };

    tooltipClose.onclick = function () {
        tooltip.style.display = "none";
    };

    closeBtn.onclick = function () {
        chatbot.style.display = "none";
        bubble.style.display = "flex";
    };

    sendBtn.onclick = sendChatbotMessage;

    input.addEventListener("keydown", function (event) {
        if (event.key === "Enter") sendChatbotMessage();
    });

    setTimeout(() => {
        if (chatbot.style.display !== "flex") {
            tooltip.style.display = "none";
        }
    }, 8000);

    document.querySelectorAll(".quick-buttons button").forEach(button => {
        button.addEventListener("click", function () {
            input.value = this.dataset.question;
            sendChatbotMessage();
        });
    });

})();

/**
 * 채팅창에 말풍선(사용자/봇) 메시지를 추가한다.
 */
function appendChatbotMessage(type, text) {
    const messages = document.getElementById("chatbotMessages");
    const div = document.createElement("div");

    div.className = type === "user" ? "user-message" : "bot-message";
    div.innerText = text;

    messages.appendChild(div);
    messages.scrollTop = messages.scrollHeight;
}

/**
 * 추천 상품 목록을 카드 형태로 채팅창에 추가한다.
 * productUrl이 있는 상품은 <a> 태그로 렌더링되어 클릭 시 새 탭에서 상품 페이지로 이동하고,
 * productUrl이 없는 상품(fallback 데이터 등)은 클릭 불가능한 <div>로 렌더링된다.
 */
function appendProductCards(products) {
    if (!products || products.length === 0) return;

    const messages = document.getElementById("chatbotMessages");
    const wrap = document.createElement("div");
    wrap.className = "product-cards";

    products.forEach(p => {
        const hasUrl = !!p.productUrl;
        const card = document.createElement(hasUrl ? "a" : "div");
        card.className = "product-card";

        if (hasUrl) {
            card.href = p.productUrl;
            card.target = "_blank";
            card.rel = "noopener noreferrer";
        }

        const priceText = (typeof p.price === "number")
            ? p.price.toLocaleString() + "원"
            : "";

        // TODO: 상품 이미지 URL 매핑 추가되면 placeholder 대신 실제 이미지로 교체
        card.innerHTML = `
            <div class="product-card-img">
                <img src="https://via.placeholder.com/100x100.png?text=Product" alt="${p.productName ?? ""}">
            </div>
            <div class="product-card-info">
                <p class="product-card-name">${p.productName ?? ""}</p>
                <p class="product-card-price">${priceText}</p>
            </div>
        `;

        wrap.appendChild(card);
    });

    messages.appendChild(wrap);
    messages.scrollTop = messages.scrollHeight;
}

/**
 * 사용자 질문을 백엔드로 전송하고, 답변과 추천 상품 카드를 채팅창에 표시한다.
 * 질문/답변 기록은 백엔드(ChatService)가 회사(clientCode)별로 DB에 자동 저장하므로,
 * 프론트에서 별도로 저장하지 않는다.
 */
async function sendChatbotMessage() {
    const input = document.getElementById("chatbotInput");
    const question = input.value.trim();

    if (!question) return;

    appendChatbotMessage("user", question);
    input.value = "";

    appendChatbotMessage("bot", "추천 상품을 찾는 중입니다...");

    const messages = document.getElementById("chatbotMessages");

    try {
        const response = await fetch(`${WIDGET_BACKEND_BASE}/api/chat`, {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                clientCode: WIDGET_CLIENT_CODE,
                question: question
            })
        });

        if (!response.ok) throw new Error(await response.text());

        const result = await response.json();
        const answer = result.answer || "추천 답변을 찾지 못했습니다.";

        messages.lastChild.remove();
        appendChatbotMessage("bot", answer);
        appendProductCards(result.recommendedProducts);

    } catch (error) {
        console.error(error);

        messages.lastChild.remove();
        appendChatbotMessage("bot", "답변을 불러오지 못했습니다. 백엔드 API를 확인해주세요.");
    }
}