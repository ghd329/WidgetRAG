function loginAsCompany(){
  localStorage.setItem('isLogin','true');
  localStorage.setItem('userType','company');
  location.href='../company/dashboard.html';
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
