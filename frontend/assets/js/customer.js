function saveHistory(question,answer){
  const history=JSON.parse(localStorage.getItem('chatHistory')||'[]');
  history.unshift({question,answer,date:new Date().toLocaleString()});
  localStorage.setItem('chatHistory',JSON.stringify(history));
}

function sendMessage() {
    const input = document.getElementById("messageInput");
    const chatBox = document.getElementById("chatBox");

    const question = input.value.trim();

    if (!question) {
        alert("질문을 입력해주세요.");
        return;
    }

    addChatMessage(question, "user");

    const answer = generateTempAnswer(question);

    setTimeout(() => {
        addChatMessage(answer, "bot");

        saveCustomerQuestion(question, answer);
        saveChatHistory(question, answer);
    }, 500);

    input.value = "";
}

function addChatMessage(text, type) {
    const chatBox = document.getElementById("chatBox");

    const message = document.createElement("div");
    message.className = "message " + type;
    message.innerHTML = text;

    chatBox.appendChild(message);
    chatBox.scrollTop = chatBox.scrollHeight;
}

function generateTempAnswer(question){

    const products =
        JSON.parse(localStorage.getItem("products")) || [];

    if(products.length===0){
        return "등록된 상품 데이터가 없습니다.";
    }

    if(question.includes("추천")){
        return "등록된 상품 데이터를 기반으로 추천 상품을 찾고 있습니다.";
    }

    if(question.includes("날씨")){
        return "현재 날씨와 상품 정보를 분석하여 추천해드릴 예정입니다.";
    }

    if(question.includes("선물")){
        return "선물하기 좋은 상품을 추천해드릴 예정입니다.";
    }

    return "RAG 검색 결과를 기반으로 답변을 생성할 예정입니다.";
}

function saveCustomerQuestion(question, answer) {
    const questionList = JSON.parse(localStorage.getItem("customerQuestions")) || [];

    questionList.unshift({
        question: question,
        answer: answer,
        date: new Date().toLocaleString("ko-KR"),
        status: "답변완료"
    });

    localStorage.setItem("customerQuestions", JSON.stringify(questionList));
}

function saveChatHistory(question, answer) {
    const history = JSON.parse(localStorage.getItem("chatHistory")) || [];

    history.unshift({
        question: question,
        answer: answer,
        date: new Date().toLocaleString("ko-KR")
    });

    localStorage.setItem("chatHistory", JSON.stringify(history));
}

function renderHistory(){
  const list=document.getElementById('historyList');
  if(!list)return;
  const history=JSON.parse(localStorage.getItem('chatHistory')||'[]');
  if(history.length===0){list.innerHTML='<div class="empty">아직 대화 기록이 없습니다.</div>';return;}
  list.innerHTML=history.map(item=>`<div class="history-card"><div class="date">${item.date}</div><p><b>Q.</b> ${item.question}</p><p style="margin-top:8px"><b>A.</b> ${item.answer}</p></div>`).join('');
}

function clearHistory(){localStorage.removeItem('chatHistory');renderHistory();}
