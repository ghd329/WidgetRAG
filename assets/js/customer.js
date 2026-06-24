function getAnswer(question){
  const q=question.toLowerCase();
  if(q.includes('배송')) return '일반 배송은 결제 완료 후 평균 2~3일 정도 소요됩니다.';
  if(q.includes('교환')||q.includes('환불')) return '상품 수령 후 7일 이내 미사용 상품에 한해 교환/환불이 가능합니다.';
  if(q.includes('사이즈')) return '상품 상세페이지의 사이즈표를 참고해주세요. 키와 체중을 알려주시면 추천도 가능합니다.';
  return '문의하신 내용을 확인했습니다. 등록된 상품/FAQ 데이터를 기준으로 답변을 준비 중입니다.';
}
function saveHistory(question,answer){
  const history=JSON.parse(localStorage.getItem('chatHistory')||'[]');
  history.unshift({question,answer,date:new Date().toLocaleString()});
  localStorage.setItem('chatHistory',JSON.stringify(history));
}
function sendMessage(){
  const input=document.getElementById('messageInput');
  const chatBox=document.getElementById('chatBox');
  const question=input.value.trim();
  if(!question)return;
  chatBox.insertAdjacentHTML('beforeend',`<div class="message user">${question}</div>`);
  const answer=getAnswer(question);
  setTimeout(()=>{
    chatBox.insertAdjacentHTML('beforeend',`<div class="message bot">${answer}</div>`);
    chatBox.scrollTop=chatBox.scrollHeight;
    saveHistory(question,answer);
  },250);
  input.value='';
}
function renderHistory(){
  const list=document.getElementById('historyList');
  if(!list)return;
  const history=JSON.parse(localStorage.getItem('chatHistory')||'[]');
  if(history.length===0){list.innerHTML='<div class="empty">아직 대화 기록이 없습니다.</div>';return;}
  list.innerHTML=history.map(item=>`<div class="history-card"><div class="date">${item.date}</div><p><b>Q.</b> ${item.question}</p><p style="margin-top:8px"><b>A.</b> ${item.answer}</p></div>`).join('');
}
function clearHistory(){localStorage.removeItem('chatHistory');renderHistory();}
