(function () {
    const chatbotButton = document.createElement("button");
    chatbotButton.innerHTML = "🤖";
    chatbotButton.id = "chatbotWidgetButton";

    chatbotButton.style.position = "fixed";
    chatbotButton.style.right = "28px";
    chatbotButton.style.bottom = "28px";
    chatbotButton.style.width = "68px";
    chatbotButton.style.height = "68px";
    chatbotButton.style.borderRadius = "50%";
    chatbotButton.style.border = "none";
    chatbotButton.style.background = "#2563eb";
    chatbotButton.style.color = "white";
    chatbotButton.style.fontSize = "30px";
    chatbotButton.style.cursor = "pointer";
    chatbotButton.style.boxShadow = "0 12px 30px rgba(37,99,235,.35)";
    chatbotButton.style.zIndex = "9999";

    const chatbotFrameBox = document.createElement("div");
    chatbotFrameBox.id = "chatbotFrameBox";

    chatbotFrameBox.style.position = "fixed";
    chatbotFrameBox.style.right = "28px";
    chatbotFrameBox.style.bottom = "110px";
    chatbotFrameBox.style.width = "430px";
    chatbotFrameBox.style.height = "720px";
    chatbotFrameBox.style.borderRadius = "24px";
    chatbotFrameBox.style.overflow = "hidden";
    chatbotFrameBox.style.boxShadow = "0 18px 45px rgba(0,0,0,.22)";
    chatbotFrameBox.style.zIndex = "9999";
    chatbotFrameBox.style.display = "none";
    chatbotFrameBox.style.background = "white";

    const iframe = document.createElement("iframe");
    iframe.src = "../customer/chatbot.html";
    iframe.style.width = "100%";
    iframe.style.height = "100%";
    iframe.style.border = "none";

    chatbotFrameBox.appendChild(iframe);

    chatbotButton.onclick = function () {
        if (chatbotFrameBox.style.display === "none") {
            chatbotFrameBox.style.display = "block";
            chatbotButton.innerHTML = "×";
            chatbotButton.style.fontSize = "36px";
        } else {
            chatbotFrameBox.style.display = "none";
            chatbotButton.innerHTML = "🤖";
            chatbotButton.style.fontSize = "30px";
        }
    };

    document.body.appendChild(chatbotFrameBox);
    document.body.appendChild(chatbotButton);
})();