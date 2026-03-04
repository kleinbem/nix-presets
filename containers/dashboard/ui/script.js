function updateClock() {
    const now = new Date();
    document.getElementById('clock-time').innerText = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    document.getElementById('clock-date').innerText = now.toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
}

async function checkStatus(card) {
    const target = card.dataset.service;
    if (!target) return;
    const indicator = card.querySelector('.status-indicator');
    const text = card.querySelector('.status-text');

    const setOnline = () => {
        indicator.classList.remove('offline');
        indicator.classList.add('online');
        text.innerText = 'Online';
    };

    const setOffline = () => {
        indicator.classList.remove('online');
        indicator.classList.add('offline');
        text.innerText = 'Inactive';
    };

    // Image load hack to bypass CORS for simple up/down checks
    const img = new Image();
    img.onload = setOnline;
    img.onerror = () => {
        try {
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 5000);
            fetch(target, { mode: 'no-cors', signal: controller.signal })
                .then(setOnline)
                .catch(setOffline);
        } catch (e) {
            setOffline();
        }
    };
    img.src = target + '/favicon.ico?' + new Date().getTime();
}

async function updateTelemetry(hostBridgeIp) {
    if (!hostBridgeIp) return;
    try {
        const response = await fetch(`http://${hostBridgeIp}:61208/api/4/quicklook`);
        const data = await response.json();
        document.getElementById('load-val').innerText = data.cpu + '%';
        document.getElementById('mem-val').innerText = data.mem + '%';
    } catch (e) {
        console.log('Telemetry offline');
    }
}

function renderDashboard(data) {
    const container = document.getElementById('content-wrapper');
    container.innerHTML = '';

    const catOrder = ["Infrastructure", "AI", "Apps", "Dev"];

    // Group items by category
    const grouped = {};
    data.services.forEach(item => {
        const cat = item.category || "Uncategorized";
        if (!grouped[cat]) grouped[cat] = [];
        grouped[cat].push(item);
    });

    const createCard = (item) => {
        const hasProxy = !!item.link && item.link !== "#";
        const isActiveClass = hasProxy ? "offline" : "online";
        const statusText = hasProxy ? "Checking..." : "Shell Ready";
        const onClick = !hasProxy ? `onclick="alert('No web interface. Access via terminal: machinectl shell martin@${item.id}'); return false;"` : "";

        return `
            <a href="${item.link}" class="card" ${hasProxy ? `data-service="${item.link}"` : ""} ${onClick}>
                <div class="icon-box">${item.icon}</div>
                <div class="card-content">
                    <h3>${item.name}</h3>
                    <p>${item.description}</p>
                    <div class="status-indicator ${isActiveClass}"><span class="status-dot"></span><span class="status-text">${statusText}</span></div>
                </div>
            </a>
        `;
    };

    const renderCategory = (cat, items) => {
        if (!items || items.length === 0) return '';
        return `
            <section class="category-section">
                <h2>${cat}</h2>
                <div class="grid">
                    ${items.map(createCard).join('')}
                </div>
            </section>
        `;
    };

    // Render in order
    catOrder.forEach(cat => {
        if (grouped[cat]) {
            container.innerHTML += renderCategory(cat, grouped[cat]);
            delete grouped[cat];
        }
    });

    // Render leftovers
    Object.keys(grouped).forEach(cat => {
        container.innerHTML += renderCategory(cat === "Uncategorized" ? "Other" : cat, grouped[cat]);
    });

    // Initial status check
    document.querySelectorAll('.card').forEach(checkStatus);
}

async function init() {
    updateClock();
    setInterval(updateClock, 1000);

    try {
        const response = await fetch('./data.json');
        const config = await response.json();

        renderDashboard(config);

        if (config.hostBridgeIp) {
            updateTelemetry(config.hostBridgeIp);
            setInterval(() => updateTelemetry(config.hostBridgeIp), 5000);
        }

        setInterval(() => document.querySelectorAll('.card').forEach(checkStatus), 15000);
    } catch (e) {
        console.error("Failed to load dashboard data:", e);
    }
}

window.onload = init;
