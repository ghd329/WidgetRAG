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