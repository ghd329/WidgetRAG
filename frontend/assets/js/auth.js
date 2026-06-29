function checkCompanyLogin(){
  if(localStorage.getItem('isLogin')!=='true'||localStorage.getItem('userType')!=='company'){
    location.href='../login/company-login.html';
  }
}
function logout(){
  localStorage.removeItem('isLogin');
  localStorage.removeItem('userType');
  location.href='../login/company-login.html';
}

function signupCompany() {

    const companyName = document.getElementById("companyName").value.trim();
    const managerName = document.getElementById("managerName").value.trim();
    const email = document.getElementById("email").value.trim();
    const password = document.getElementById("password").value;
    const passwordCheck = document.getElementById("passwordCheck").value;

    if (!companyName || !managerName || !email || !password || !passwordCheck) {
        alert("모든 항목을 입력해주세요.");
        return;
    }

    // 이메일 형식
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

    if (!emailRegex.test(email)) {
        alert("올바른 이메일 형식으로 입력해주세요.");
        return;
    }

    // 비밀번호
    // 영문 + 숫자 + 특수문자 + 8자 이상
    const passwordRegex =
        /^(?=.*[A-Za-z])(?=.*\d)(?=.*[!@#$%^&*(),.?":{}|<>]).{8,}$/;

    if (!passwordRegex.test(password)) {
        alert("비밀번호는 영문, 숫자, 특수문자를 모두 포함한 8자 이상이어야 합니다.");
        return;
    }

    if (password !== passwordCheck) {
        alert("비밀번호가 일치하지 않습니다.");
        return;
    }

    // (임시) 회원가입 정보 저장
    localStorage.setItem("companyName", companyName);
    localStorage.setItem("managerName", managerName);
    localStorage.setItem("companyEmail", email);

    alert("회원가입이 완료되었습니다.");

    // 로그인 페이지 이동
    location.href = "company-login.html";
}