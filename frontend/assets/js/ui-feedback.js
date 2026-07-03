/* Shared toast / confirm-modal / inline field-error helpers.
   Injects its own DOM (toast container, confirm modal) on first use,
   so a page only needs to include this script + ui-feedback.css. */

(function () {
    function getToastContainer() {
        let container = document.getElementById("uifToastContainer");

        if (!container) {
            container = document.createElement("div");
            container.id = "uifToastContainer";
            container.className = "uif-toast-container";
            document.body.appendChild(container);
        }

        return container;
    }

    window.showToast = function (message, type = "success") {
        const container = getToastContainer();
        const toast = document.createElement("div");

        toast.className = `uif-toast uif-toast-${type}`;
        toast.textContent = message;
        container.appendChild(toast);

        requestAnimationFrame(() => toast.classList.add("show"));

        setTimeout(() => {
            toast.classList.remove("show");
            toast.addEventListener("transitionend", () => toast.remove(), { once: true });
        }, 2500);
    };

    function getConfirmModal() {
        let overlay = document.getElementById("uifConfirmModal");

        if (overlay) {
            return overlay;
        }

        overlay = document.createElement("div");
        overlay.id = "uifConfirmModal";
        overlay.className = "uif-modal-overlay";
        overlay.innerHTML = `
            <div class="uif-modal-box">
                <h3></h3>
                <p></p>
                <div class="uif-modal-actions">
                    <button type="button" class="uif-btn uif-btn-secondary" data-role="cancel"></button>
                    <button type="button" class="uif-btn uif-btn-danger" data-role="confirm"></button>
                </div>
            </div>
        `;
        document.body.appendChild(overlay);

        return overlay;
    }

    window.showConfirm = function (message, options = {}) {
        const {
            title = "확인",
            confirmText = "확인",
            cancelText = "취소",
            danger = true
        } = options;

        const overlay = getConfirmModal();
        const confirmBtn = overlay.querySelector('[data-role="confirm"]');
        const cancelBtn = overlay.querySelector('[data-role="cancel"]');

        overlay.querySelector("h3").textContent = title;
        overlay.querySelector("p").textContent = message;
        confirmBtn.textContent = confirmText;
        confirmBtn.className = `uif-btn ${danger ? "uif-btn-danger" : "uif-btn-primary"}`;
        cancelBtn.textContent = cancelText;

        overlay.classList.add("show");

        return new Promise((resolve) => {
            function close(result) {
                overlay.classList.remove("show");
                confirmBtn.removeEventListener("click", onConfirm);
                cancelBtn.removeEventListener("click", onCancel);
                overlay.removeEventListener("click", onOverlayClick);
                resolve(result);
            }

            function onConfirm() {
                close(true);
            }

            function onCancel() {
                close(false);
            }

            function onOverlayClick(event) {
                if (event.target === overlay) {
                    close(false);
                }
            }

            confirmBtn.addEventListener("click", onConfirm);
            cancelBtn.addEventListener("click", onCancel);
            overlay.addEventListener("click", onOverlayClick);
        });
    };

    window.setFieldError = function (inputId, errorId, message) {
        const input = document.getElementById(inputId);
        const errorEl = document.getElementById(errorId);

        if (!input || !errorEl) {
            return;
        }

        if (message) {
            input.classList.add("uif-input-error");
            errorEl.textContent = message;
            errorEl.classList.add("show");
        } else {
            input.classList.remove("uif-input-error");
            errorEl.textContent = "";
            errorEl.classList.remove("show");
        }
    };
})();
