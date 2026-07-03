function initPage() {
  checkCompanyLogin();
  applyTheme();
  applyCompanyName();
}

function applyCompanyName() {
  const companyName = localStorage.getItem("companyName");
  const label = document.getElementById("companyNameLabel");

  if (companyName && label) {
    label.innerText = companyName + " 관리자님";
  }
}

function applyTheme() {
  const theme = localStorage.getItem("theme");

  if (theme === "dark") {
    document.body.classList.add("dark-mode");
  } else {
    document.body.classList.remove("dark-mode");
  }
}