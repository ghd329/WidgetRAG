function initPage() {
  checkCompanyLogin();
  applyTheme();
  applyCompanyName();
  applyRoleVisibility();
}

function applyRoleVisibility() {
  const role = localStorage.getItem("role");

  document.querySelectorAll(".owner-only").forEach(el => {
    if (role !== "COMPANY_OWNER") {
      el.style.display = "none";
    }
  });
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