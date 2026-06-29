function initPage() {
  checkCompanyLogin();
  applyTheme();
}

function uploadFile() {
  const file = document.getElementById('fileInput')?.files[0];

  if (!file) {
    alert('파일을 선택해주세요.');
    return;
  }

  alert(file.name + ' 업로드 완료!');
}

function copyScript() {
  const code = document.getElementById('scriptCode');

  if (!code) return;

  navigator.clipboard.writeText(code.value)
    .then(() => alert('코드가 복사되었습니다.'));
}

function addProduct() {
  alert('상품 추가 기능은 백엔드 연결 후 동작합니다.');
}

function saveAnswer() {
  alert('답변이 저장되었습니다.');
}

function saveSettings() {
  alert('설정이 저장되었습니다.');
}

function applyTheme() {
  const theme = localStorage.getItem("theme");

  if (theme === "dark") {
    document.body.classList.add("dark-mode");
  } else {
    document.body.classList.remove("dark-mode");
  }
}

function saveTheme() {
  const theme = document.getElementById("themeSelect").value;

  localStorage.setItem("theme", theme);
  applyTheme();

  alert("디스플레이 모드가 저장되었습니다.");
}

function initPage() {

    checkCompanyLogin();

    applyTheme();
}