const API_BASE = "http://localhost:8080";

async function loadCompanies() {

    try {

        const response = await fetch(`${API_BASE}/api/admin/companies/pending`);

        if (!response.ok) {
            throw new Error("기업 목록을 불러오지 못했습니다.");
        }

        const companies = await response.json();

        const tbody = document.getElementById("companyBody");

        tbody.innerHTML = "";

        if (companies.length === 0) {
            tbody.innerHTML = `
                <tr>
                    <td colspan="5" style="text-align:center;">
                        승인 대기 중인 기업이 없습니다.
                    </td>
                </tr>
            `;
            return;
        }

        companies.forEach(company => {

            tbody.innerHTML += `
                <tr>

                    <td>${company.companyName}</td>

                    <td>${company.ownerName ?? "-"}</td>

                    <td>${company.ownerEmail}</td>

                    <td>${company.status}</td>

                    <td>

                        <button onclick="approve(${company.companyId})">
                            승인
                        </button>

                        <button onclick="reject(${company.companyId})">
                            반려
                        </button>

                    </td>

                </tr>
            `;

        });

    } catch (e) {
        alert(e.message);
    }

}

async function approve(companyId){

    if(!confirm("해당 기업을 승인하시겠습니까?")) return;

    const response = await fetch(
        `${API_BASE}/api/admin/companies/${companyId}/approve`,
        {
            method: "POST"
        }
    );

    if(response.ok){
        alert("기업 승인 완료");
        loadCompanies();
    }

}

async function reject(companyId){

    if(!confirm("해당 기업을 반려하시겠습니까?")) return;

    const response = await fetch(
        `${API_BASE}/api/admin/companies/${companyId}/reject`,
        {
            method: "POST"
        }
    );

    if(response.ok){
        alert("기업 반려 완료");
        loadCompanies();
    }

}

loadCompanies();