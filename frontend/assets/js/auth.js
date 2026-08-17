// 관리자 화면 공통 인증 실패 처리.
// 401 = 세션 없음(로그아웃/만료), 403 = 로그인은 돼 있으나 관리자 권한이 아님
// (예: 회사 계정으로 로그인한 세션으로 관리자 페이지를 연 경우).
// 두 경우 모두 화면에 "불러오지 못했습니다"만 남기지 말고 로그인 페이지로 되돌립니다.
function handleAdminAuthFailure(response){
  if(response.status!==401&&response.status!==403) return false;

  const reason=response.status===403?'admin-required':'session-expired';

  localStorage.clear();
  location.href='../login/company-login.html?reason='+reason;
  return true;
}

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