#!/usr/bin/env node
'use strict';

const path = require('path');
const fs = require('fs');

/**
 * Resolve .env the same way operators deploy: bundle root, classic runner/, or nested toolkit/runner/.
 */
function loadRunnerDotenv() {
    const candidates = [
        path.join(__dirname, '.env'),
        path.join(__dirname, 'runner', '.env'),
        path.join(__dirname, 'toolkit', 'runner', '.env'),
    ];
    const triedPaths = [...candidates];

    for (const envPath of candidates) {
        try {
            if (fs.existsSync(envPath)) {
                require('dotenv').config({ path: envPath });
                return { loadedPath: envPath, triedPaths };
            }
        } catch {
            // ignore unreadable paths
        }
    }

    require('dotenv').config();
    return { loadedPath: null, triedPaths };
}

const dotenvResult = loadRunnerDotenv();

/**
 * Best-effort short git revision when running from a git checkout (no network).
 */
function readGitRevisionShort() {
    try {
        const gitDir = path.join(__dirname, '.git');
        const headPath = path.join(gitDir, 'HEAD');
        if (!fs.existsSync(headPath)) {
            return null;
        }
        let head = fs.readFileSync(headPath, 'utf8').trim();
        if (head.startsWith('ref:')) {
            const ref = head.replace(/^ref:\s*/i, '').trim();
            const refFile = path.join(gitDir, ref);
            if (fs.existsSync(refFile)) {
                head = fs.readFileSync(refFile, 'utf8').trim();
            } else {
                const packed = path.join(gitDir, 'packed-refs');
                if (fs.existsSync(packed)) {
                    const lines = fs.readFileSync(packed, 'utf8').split(/\r?\n/);
                    for (const line of lines) {
                        if (line.startsWith('#') || line === '') {
                            continue;
                        }
                        const m = line.match(/^([0-9a-f]+) (.+)$/);
                        if (m && m[2] === ref) {
                            head = m[1];
                            break;
                        }
                    }
                }
            }
        }
        if (/^[0-9a-f]{7,40}$/i.test(head)) {
            return head.length > 7 ? head.slice(0, 7) : head;
        }
    } catch {
        return null;
    }
    return null;
}

const express = require('express');
const rateLimit = require('express-rate-limit');
const os = require('os');
const https = require('https');
const net = require('net');
const crypto = require('crypto');
const { URL } = require('url');
const { spawn, spawnSync } = require('child_process');

const app = express();

/** Prefer MANAGED_AGENT_*; RELEASEPANEL_* remains as legacy alias for the same values. */
function envPair(primary, legacy, defaultValue = '') {
    const v = process.env[primary] || process.env[legacy];
    if (v !== undefined && v !== '') {
        return v;
    }
    return defaultValue;
}

function resolvedRunnerVersionLabel() {
    const envRaw = envPair('MANAGED_AGENT_RUNNER_VERSION', 'RELEASEPANEL_RUNNER_VERSION', '');
    if (envRaw && envRaw.trim() !== '') {
        return envRaw.trim();
    }
    return readGitRevisionShort() || 'local';
}

function envTruthy(primary, legacy) {
 const v = process.env[primary] || process.env[legacy];
 return v === '1' || v === 'true' || v === 'TRUE' || v === 'yes' || v === 'YES' || v === 'on' || v === 'ON';
}

/** Install key for onboarding only; register-server.sh may stage it until REGISTRATION_COMPLETE=1. */
function envOnboardingInstallKey() {
    const keys = [
        'MANAGED_AGENT_ACCOUNT_KEY',
        'RELEASEPANEL_AGENT_ACCOUNT_KEY',
        'MANAGED_AGENT_PANEL_INSTALL_KEY',
        'RELEASEPANEL_INSTALL_KEY',
        'RELEASEPANEL_PANEL_INSTALL_KEY',
    ];
    for (const k of keys) {
        const v = process.env[k];
        if (v !== undefined && String(v).trim() !== '') {
            return String(v).trim();
        }
    }
    return '';
}

function registrationComplete() {
    return envTruthy('MANAGED_AGENT_REGISTRATION_COMPLETE', 'RELEASEPANEL_REGISTRATION_COMPLETE');
}

const PANEL_ONBOARDING_HINT_THROTTLE_MS = 5 * 60 * 1000;
/** @type {Record<string, number>} */
const lastOnboardingRejectLog = Object.create(null);

/**
 * When registration is still incomplete, surface install-key / onboarding errors on stderr
 * (visible in journalctl) — appendLog() only writes the JSON file and is easy to miss.
 */
function maybePanelOnboardingRejectedConsoleHint(pathname, panelResponse) {
    if (registrationComplete()) {
        return;
    }
    const code = panelResponse?.json?.code;
    if (code == null || typeof code !== 'string' || code === '') {
        return;
    }
    const onboarding = code.startsWith('install_key_')
        || code === 'account_install_key_required'
        || code === 'account_install_key_mismatch';
    if (!onboarding) {
        return;
    }
    const now = Date.now();
    const slot = `${pathname}:${code}`;
    const prev = lastOnboardingRejectLog[slot] || 0;
    if (now - prev < PANEL_ONBOARDING_HINT_THROTTLE_MS) {
        return;
    }
    lastOnboardingRejectLog[slot] = now;
    const msg = panelResponse.json?.message || '';
    const hint = panelResponse.json?.hint || '';
    const detail = `${code}${msg ? ` — ${msg}` : ''}${hint ? `. ${hint}` : ''}`;
    console.error(
        `[managed-deploy-agent] ${pathname}: ${detail} `
        + 'Registration is incomplete. In ReleasePanel, rotate/copy the install key if needed, then run '
        + '`sudo managed-deploy join <panel-url> --account-key=<key>` '
        + '(or re-run install with --account-key=). '
        + 'Repeated messages are throttled to every '
        + `${Math.round(PANEL_ONBOARDING_HINT_THROTTLE_MS / 1000)}s per error code.`,
    );
}

/** When unset, default poll on if a panel URL is configured (hosted / NAT installs). Opt out: MANAGED_AGENT_POLL_ENABLED=false */
function envPollEnabled(panelUrlNormalized) {
 const raw = process.env.MANAGED_AGENT_POLL_ENABLED || process.env.RELEASEPANEL_POLL_ENABLED;
 if (raw === undefined || String(raw).trim() === '') {
 return Boolean(panelUrlNormalized && String(panelUrlNormalized).trim() !== '');
 }
 return envTruthy('MANAGED_AGENT_POLL_ENABLED', 'RELEASEPANEL_POLL_ENABLED');
}

const host = envPair('MANAGED_AGENT_RUNNER_HOST', 'RELEASEPANEL_RUNNER_HOST', '127.0.0.1');
const port = Number.parseInt(envPair('MANAGED_AGENT_RUNNER_PORT', 'RELEASEPANEL_RUNNER_PORT', '9000'), 10);
let apiKey = envPair('MANAGED_AGENT_RUNNER_KEY', 'RELEASEPANEL_RUNNER_KEY', '');
const logPath = envPair('MANAGED_AGENT_RUNNER_LOG', 'RELEASEPANEL_RUNNER_LOG', '/var/log/managed-deploy-agent.log');
const toolkitPath = path.resolve(
    envPair('MANAGED_AGENT_TOOLKIT_DIR', 'RELEASEPANEL_TOOLKIT_DIR', path.join(__dirname, '..')),
);
const normalTimeoutMs = Number.parseInt(
    envPair('MANAGED_AGENT_RUNNER_NORMAL_TIMEOUT_MS', 'RELEASEPANEL_RUNNER_NORMAL_TIMEOUT_MS', '120000'),
    10,
);
const deployTimeoutMs = Number.parseInt(
    envPair('MANAGED_AGENT_RUNNER_DEPLOY_TIMEOUT_MS', 'RELEASEPANEL_RUNNER_DEPLOY_TIMEOUT_MS', '900000'),
    10,
);
const provisionTimeoutMs = Number.parseInt(
    envPair('MANAGED_AGENT_PROVISION_TIMEOUT_MS', 'RELEASEPANEL_PROVISION_TIMEOUT_MS', '900000'),
    10,
);
const panelUrl = envPair('MANAGED_AGENT_PANEL_URL', 'RELEASEPANEL_PANEL_URL', '').replace(/\/+$/, '');
const heartbeatIntervalMs = Number.parseInt(
 envPair('MANAGED_AGENT_RUNNER_HEARTBEAT_MS', 'RELEASEPANEL_RUNNER_HEARTBEAT_MS', '30000'),
 10,
);
const pollEnabled = envPollEnabled(panelUrl);
const pollIntervalMs = Math.max(
    3000,
    Number.parseInt(envPair('MANAGED_AGENT_POLL_INTERVAL_SECONDS', 'RELEASEPANEL_POLL_INTERVAL_SECONDS', '5'), 10) * 1000,
);
const panelInsecureTls = envTruthy('MANAGED_AGENT_PANEL_INSECURE_TLS', 'RELEASEPANEL_PANEL_INSECURE_TLS');

/** In-process cache: `undefined` = not attempted yet, string = IPv4, `null` = lookup failed */
let cachedDetectedPublicIpv4;

/**
 * Match bash `releasepanel_is_routable_agent_ipv4` / Python `IPv4Address.is_global` closely enough for agent self-reporting.
 * @param {unknown} ip
 * @returns {boolean}
 */
function isRoutablePublicIpv4(ip) {
    if (typeof ip !== 'string') {
        return false;
    }
    const s = ip.trim();
    if (!net.isIPv4(s)) {
        return false;
    }
    const oct = s.split('.').map((x) => Number.parseInt(x, 10));
    if (oct.some((n) => n > 255 || n < 0 || Number.isNaN(n))) {
        return false;
    }
    const [a, b, c] = oct;
    if (a === 0 || a === 10 || a === 127) {
        return false;
    }
    if (a === 169 && b === 254) {
        return false;
    }
    if (a === 172 && b >= 16 && b <= 31) {
        return false;
    }
    if (a === 192 && b === 168) {
        return false;
    }
    if (a === 100 && b >= 64 && b <= 127) {
        return false;
    }
    if (a === 192 && b === 0 && c === 0) {
        return false;
    }
    if (a === 192 && b === 0 && c === 2) {
        return false;
    }
    if (a === 198 && b === 51 && c === 100) {
        return false;
    }
    if (a === 203 && b === 0 && c === 113) {
        return false;
    }
    if (a === 198 && b >= 18 && b <= 19) {
        return false;
    }
    if (a >= 224) {
        return false;
    }
    return true;
}

async function fetchTextProbe(url, timeoutMs = 12000) {
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    try {
        const res = await fetch(url, {
            signal: ac.signal,
            headers: { Accept: 'text/plain,*/*' },
        });
        clearTimeout(timer);
        if (!res.ok) {
            return '';
        }
        return (await res.text()).trim();
    } catch {
        clearTimeout(timer);
        return '';
    }
}

async function detectPublicIpv4ForRunner() {
    if (cachedDetectedPublicIpv4 !== undefined) {
        return cachedDetectedPublicIpv4;
    }
    const urls = [
        'https://api.ipify.org',
        'https://ifconfig.me/ip',
        'https://checkip.amazonaws.com',
        'https://api4.ipify.org',
    ];
    for (const url of urls) {
        const raw = await fetchTextProbe(url);
        const ip = (raw.split(/\s/)[0] || '').trim();
        if (isRoutablePublicIpv4(ip)) {
            console.error(`[managed-deploy-agent] Detected public IP for runner_url: ${ip}`);
            cachedDetectedPublicIpv4 = ip;
            return ip;
        }
    }
    console.error('[managed-deploy-agent] Unable to determine public IP for runner');
    cachedDetectedPublicIpv4 = null;
    return null;
}

const runningEnvActions = new Map();
const commandRuns = new Map();
const maxTailBytes = 256 * 1024;
const maxRunOutputBytes = 512 * 1024;
const maxAgentPanelOutputChars = 200000;
const runTtlMs = 30 * 60 * 1000;

function truncateForAgentPanel(text, maxLen) {
    const s = String(text || '');
    if (s.length <= maxLen) {
        return s;
    }
    return `...[truncated]...\n${s.slice(s.length - (maxLen - 22))}`;
}

function explainProvisionSudoFailure(stdout, stderr) {
    const blob = `${stderr || ''}\n${stdout || ''}`;
    const low = blob.toLowerCase();
    if (
        low.includes('a password is required')
        || low.includes('sorry, try again')
        || (low.includes('sudo:') && low.includes('password'))
        || low.includes('interactive authentication required')
        || low.includes('sudo: no tty present')
        || low.includes('a terminal is required to read the password')
    ) {
        return ' sudo requires a password or is not configured for non-interactive use — configure NOPASSWD for the agent user or use SSH provisioning.';
    }
    return '';
}

const actionAliases = {};

const siteActions = {
    status: {
        method: 'GET',
        route: '/status/:site/:env',
        args: (site, env) => siteCommandArgs('status', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    deploy: {
        method: 'POST',
        route: '/deploy/:site/:env',
        args: (site, env) => siteCommandArgs('deploy', site, env),
        timeoutMs: deployTimeoutMs,
        locked: true,
    },
    rollback: {
        method: 'POST',
        route: '/rollback/:site/:env',
        args: (site, env) => siteCommandArgs('rollback', site, env),
        timeoutMs: deployTimeoutMs,
        locked: true,
    },
    repair: {
        method: 'POST',
        route: '/repair/:site/:env',
        args: (site, env) => siteCommandArgs('repair', site, env),
        timeoutMs: normalTimeoutMs,
        locked: true,
    },
    nginx: {
        method: 'POST',
        route: '/nginx/:site/:env',
        args: (site, env) => siteCommandArgs('nginx', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    ssl: {
        method: 'POST',
        route: '/ssl/:site/:env',
        args: (site, env) => siteCommandArgs('ssl', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    workers: {
        method: 'POST',
        route: '/workers/:site/:env',
        args: (site, env) => siteCommandArgs('workers', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    smoke: {
        method: 'POST',
        route: '/smoke/:site/:env',
        args: (site, env) => siteCommandArgs('smoke', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    logs: {
        method: 'POST',
        route: '/logs/:site/:env',
        args: (site, env) => siteCommandArgs('logs', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
    deployKey: {
        method: 'POST',
        route: '/deploy-key/:site/:env',
        args: (site, env) => siteCommandArgs('deployKey', site, env),
        timeoutMs: normalTimeoutMs,
        locked: false,
    },
};

const promoteAction = {
    method: 'POST',
    args: (site, fromEnv, toEnv) => ({
        command: '/bin/bash',
        args: [scriptPath('site-promote.sh'), site, fromEnv, toEnv],
    }),
    timeoutMs: deployTimeoutMs,
    locked: true,
};

if (dotenvResult.loadedPath) {
    console.error(`[managed-deploy-agent] loaded env file: ${dotenvResult.loadedPath}`);
} else {
    console.error(`[managed-deploy-agent] no .env found; checked: ${dotenvResult.triedPaths.join(', ')}`);
}

function joinTokenFromEnv() {
    return envPair('MANAGED_AGENT_JOIN_TOKEN', 'RELEASEPANEL_JOIN_TOKEN', '').trim();
}

const awaitingJoinBootstrap = !!joinTokenFromEnv() && (!apiKey || apiKey === '' || apiKey === 'CHANGE_ME');

if ((!apiKey || apiKey === 'CHANGE_ME') && !awaitingJoinBootstrap) {
    console.error('MANAGED_AGENT_RUNNER_KEY (or legacy RELEASEPANEL_RUNNER_KEY) must be set to the same value as RELEASEPANEL_RUNNER_KEY in the panel shared/.env.');
    console.error('Repair: sudo releasepanel heal-self-runner   or copy the key into the runner .env then: sudo systemctl restart managed-deploy-agent');
    process.exit(1);
}

if (awaitingJoinBootstrap && (!panelUrl || panelUrl.trim() === '')) {
    console.error('MANAGED_AGENT_JOIN_TOKEN (or legacy RELEASEPANEL_JOIN_TOKEN) is set without MANAGED_AGENT_PANEL_URL.');
    console.error('Set the panel URL in .env matching your control plane, then restart.');
    process.exit(1);
}

if (!['127.0.0.1', '0.0.0.0'].includes(host)) {
    console.error('MANAGED_AGENT_RUNNER_HOST (or legacy RELEASEPANEL_RUNNER_HOST) must be 127.0.0.1 or 0.0.0.0.');
    process.exit(1);
}

if (panelInsecureTls && panelUrl) {
    console.warn('[managed-deploy-agent] MANAGED_AGENT_PANEL_INSECURE_TLS is set; TLS certificate verification is disabled for HTTPS heartbeats to the control plane. Use only for trusted staging or until a public CA cert is installed on the panel.');
}

app.disable('x-powered-by');
app.use(rateLimit({
    windowMs: 60 * 1000,
    max: 120,
    standardHeaders: true,
    legacyHeaders: false,
    skip: (request) => request.path === '/health' || request.path === '/api/health',
}));
app.use(express.json({ limit: '256kb' }));
app.use(express.urlencoded({ extended: true, limit: '256kb' }));

function appendLog(entry) {
    const line = JSON.stringify({
        timestamp: new Date().toISOString(),
        ...entry,
    });

    fs.appendFile(logPath, `${line}\n`, () => {});
}

function requesterIp(request) {
    return request.ip || request.socket?.remoteAddress || 'unknown';
}

function runnerCorrelationId(request) {
    const raw = request.get('X-Runner-Correlation-Id');
    if (raw == null || typeof raw !== 'string') {
        return null;
    }
    const trimmed = raw.trim();

    return trimmed !== '' ? trimmed : null;
}

function commandAvailable(command) {
    return spawnSync('command', ['-v', command], {
        shell: true,
        stdio: 'ignore',
        timeout: 5000,
    }).status === 0;
}

function serviceActive(service) {
    return spawnSync('systemctl', ['is-active', '--quiet', service], {
        stdio: 'ignore',
        timeout: 5000,
    }).status === 0;
}

function installedPhpVersions() {
    const runDir = '/run/php';

    if (!fs.existsSync(runDir)) {
        return [];
    }

    return fs.readdirSync(runDir)
        .map((file) => file.match(/^php([0-9]+\.[0-9]+)-fpm\.sock$/)?.[1] || null)
        .filter(Boolean)
        .sort();
}

function healthContract() {
    let publicIp = envPair('MANAGED_AGENT_RUNNER_PUBLIC_IP', 'RELEASEPANEL_RUNNER_PUBLIC_IP', '');
    publicIp = publicIp && isRoutablePublicIpv4(publicIp) ? publicIp : '';
    if (!publicIp && typeof cachedDetectedPublicIpv4 === 'string') {
        publicIp = cachedDetectedPublicIpv4;
    }
    const gitRevision = readGitRevisionShort();
    const version = resolvedRunnerVersionLabel();

    return {
        status: 'ok',
        runner: 'managed-deploy-agent',
        version,
        agent_version: version,
        git_revision: gitRevision,
        hostname: os.hostname(),
        public_ip: publicIp ? publicIp : null,
        time: new Date().toISOString(),
        php_versions: installedPhpVersions(),
        nginx: commandAvailable('nginx') && serviceActive('nginx'),
        supervisor: commandAvailable('supervisorctl') && serviceActive('supervisor'),
        redis: commandAvailable('redis-server') && (serviceActive('redis-server') || serviceActive('redis')),
    };
}

/**
 * Panel request signing (optional on panel via RELEASEPANEL_REQUIRE_RUNNER_REQUEST_SIGNATURE).
 * Canonical string: `${unixSeconds}\n${rawBody}` — HMAC-SHA256 keyed by runner key, hex digest.
 */
function runnerRequestSignatureHeaders(runnerKey, rawBody) {
    const ts = String(Math.floor(Date.now() / 1000));
    const sig = crypto.createHmac('sha256', runnerKey).update(`${ts}\n${rawBody}`).digest('hex');
    return {
        'X-Runner-Timestamp': ts,
        'X-Runner-Signature': sig,
    };
}

async function panelFetchJson(pathname, { method = 'POST', bodyObj = {} } = {}) {
    const targetUrl = `${panelUrl}${pathname}`;
    const bodyStr = JSON.stringify(bodyObj ?? {});
    const sig = apiKey ? runnerRequestSignatureHeaders(apiKey, bodyStr) : {};
    const initHeaders = {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-RUNNER-KEY': apiKey,
        ...sig,
    };
    const onboard = envOnboardingInstallKey();
    if (
        onboard
        && !registrationComplete()
        && (pathname === '/api/runner-heartbeat' || pathname === '/api/register-runner')
    ) {
        initHeaders['X-ACCOUNT-INSTALL-KEY'] = onboard;
        initHeaders['X-RELEASEPANEL-INSTALL-KEY'] = onboard;
    }
    // Account install key is for registration / heartbeat bootstrap only (join-panel + register-server.sh).
    // Heartbeats, poll, and job-result authenticate with X-RUNNER-KEY; signatures add replay/tamper resistance when the panel enforces them.

    if (!(panelInsecureTls && targetUrl.startsWith('https:'))) {
        const res = await fetch(targetUrl, { method, headers: initHeaders, body: bodyStr });
        const text = await res.text();
        let json = {};
        try {
            json = text ? JSON.parse(text) : {};
        } catch {
            json = { _parse_error: true };
        }

        return { ok: res.ok, status: res.status, json };
    }

    const u = new URL(targetUrl);
    const headers = { ...initHeaders, 'Content-Length': Buffer.byteLength(bodyStr) };

    return new Promise((resolve, reject) => {
        const req = https.request(
            {
                hostname: u.hostname,
                port: u.port || 443,
                path: `${u.pathname}${u.search}`,
                method,
                headers,
                rejectUnauthorized: false,
            },
            (res) => {
                const chunks = [];
                res.on('data', (c) => chunks.push(c));
                res.on('end', () => {
                    const text = Buffer.concat(chunks).toString('utf8');
                    let json = {};
                    try {
                        json = text ? JSON.parse(text) : {};
                    } catch {
                        json = { _parse_error: true };
                    }
                    resolve({
                        ok: res.statusCode >= 200 && res.statusCode < 300,
                        status: res.statusCode || 0,
                        json,
                    });
                });
            },
        );
        req.on('error', reject);
        req.write(bodyStr);
        req.end();
    });
}

/** POST /api/register-runner with X-JOIN-TOKEN only (before a runner key exists). */
async function panelPostJoinRegistration(bodyObj, joinTokenPlain) {
    const targetUrl = `${panelUrl}/api/register-runner`;
    const bodyStr = JSON.stringify(bodyObj ?? {});
    const initHeaders = {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-JOIN-TOKEN': joinTokenPlain,
    };

    if (!(panelInsecureTls && targetUrl.startsWith('https:'))) {
        const res = await fetch(targetUrl, { method: 'POST', headers: initHeaders, body: bodyStr });
        const text = await res.text();
        let json = {};
        try {
            json = text ? JSON.parse(text) : {};
        } catch {
            json = { _parse_error: true };
        }

        return { ok: res.ok, status: res.status, json };
    }

    const u = new URL(targetUrl);
    const headers = { ...initHeaders, 'Content-Length': Buffer.byteLength(bodyStr) };

    return new Promise((resolve, reject) => {
        const req = https.request(
            {
                hostname: u.hostname,
                port: u.port || 443,
                path: `${u.pathname}${u.search}`,
                method: 'POST',
                headers,
                rejectUnauthorized: false,
            },
            (res) => {
                const chunks = [];
                res.on('data', (c) => chunks.push(c));
                res.on('end', () => {
                    const text = Buffer.concat(chunks).toString('utf8');
                    let json = {};
                    try {
                        json = text ? JSON.parse(text) : {};
                    } catch {
                        json = { _parse_error: true };
                    }
                    resolve({
                        ok: res.statusCode >= 200 && res.statusCode < 300,
                        status: res.statusCode || 0,
                        json,
                    });
                });
            },
        );
        req.on('error', reject);
        req.write(bodyStr);
        req.end();
    });
}

/**
 * Persist issued runner key and strip join-token lines from .env (one-time join).
 * @param {string} runnerKeyPlain
 */
async function persistRunnerKeyStripJoin(runnerKeyPlain) {
    const envPath = dotenvResult.loadedPath || path.join(__dirname, '.env');
    let raw = '';
    try {
        raw = await fs.promises.readFile(envPath, 'utf8');
    } catch {
        raw = '';
    }
    const lines = raw.split(/\r?\n/);
    const out = [];
    for (const line of lines) {
        const t = line.trim();
        if (
            /^MANAGED_AGENT_JOIN_TOKEN=/i.test(t)
            || /^RELEASEPANEL_JOIN_TOKEN=/i.test(t)
            || /^MANAGED_AGENT_RUNNER_KEY=/i.test(t)
            || /^RELEASEPANEL_RUNNER_KEY=/i.test(t)
        ) {
            continue;
        }
        out.push(line);
    }
    out.push(`MANAGED_AGENT_RUNNER_KEY=${runnerKeyPlain}`);
    await fs.promises.writeFile(envPath, `${out.join('\n').replace(/\n+$/, '')}\n`, 'utf8');
}

let joinRegistrationBusy = false;

function registerIfNeeded() {
    void registerViaJoinToken();
}

async function registerViaJoinToken() {
    const joinToken = joinTokenFromEnv();
    if (!joinToken) {
        return;
    }
    if (apiKey && apiKey !== 'CHANGE_ME' && apiKey !== '') {
        return;
    }
    if (joinRegistrationBusy) {
        return;
    }
    joinRegistrationBusy = true;
    try {
        console.error('[managed-deploy-agent] Registering with panel (join token)...');
        const hn = os.hostname();
        /** @type {Record<string, unknown>} */
        const body = { server_name: hn, hostname: hn };
        const explicitPublicUrl = envPair('MANAGED_AGENT_RUNNER_PUBLIC_URL', 'RELEASEPANEL_RUNNER_PUBLIC_URL', '').trim();
        const envPip = envPair('MANAGED_AGENT_RUNNER_PUBLIC_IP', 'RELEASEPANEL_RUNNER_PUBLIC_IP', '').trim();
        const routableEnvPip = envPip && isRoutablePublicIpv4(envPip) ? envPip : '';
        let detected = null;
        if (explicitPublicUrl === '' && !routableEnvPip) {
            detected = await detectPublicIpv4ForRunner();
        }
        if (routableEnvPip) {
            body.public_ip = routableEnvPip;
        } else if (detected) {
            body.public_ip = detected;
        }
        if (explicitPublicUrl !== '') {
            body.runner_url = explicitPublicUrl;
        } else if (routableEnvPip) {
            body.runner_url = `http://${routableEnvPip}:${port}`;
        } else if (detected) {
            body.runner_url = `http://${detected}:${port}`;
        }

        const res = await panelPostJoinRegistration(body, joinToken);
        const data = res.json;
        if (!res.ok || !data || data.success !== true || typeof data.runner_key !== 'string' || data.runner_key.trim() === '') {
            console.error('[managed-deploy-agent] Join registration failed:', data || `HTTP ${res.status}`);
            setTimeout(registerIfNeeded, 5000);
            return;
        }
        apiKey = data.runner_key.trim();
        process.env.MANAGED_AGENT_RUNNER_KEY = apiKey;
        delete process.env.MANAGED_AGENT_JOIN_TOKEN;
        delete process.env.RELEASEPANEL_JOIN_TOKEN;
        try {
            await persistRunnerKeyStripJoin(apiKey);
        } catch (e) {
            const msg = e && typeof e.message === 'string' ? e.message : String(e);
            console.error('[managed-deploy-agent] Could not persist runner key to .env:', msg);
        }
        console.log('[managed-deploy-agent] Join registration successful');
        console.log('[managed-deploy-agent] Registered as:', data.server_id);
    } catch (error) {
        const msg = error && typeof error.message === 'string' ? error.message : String(error);
        console.error('[managed-deploy-agent] Join registration error:', msg);
        setTimeout(registerIfNeeded, 5000);
    } finally {
        joinRegistrationBusy = false;
    }
}

async function sendHeartbeat() {
    if (!panelUrl || !apiKey) {
        return;
    }

    try {
        const heartbeatPayload = {
            hostname: os.hostname(),
        };

        const explicitPublicUrl = envPair('MANAGED_AGENT_RUNNER_PUBLIC_URL', 'RELEASEPANEL_RUNNER_PUBLIC_URL', '').trim();
        const envPip = envPair('MANAGED_AGENT_RUNNER_PUBLIC_IP', 'RELEASEPANEL_RUNNER_PUBLIC_IP', '').trim();
        const routableEnvPip = envPip && isRoutablePublicIpv4(envPip) ? envPip : '';

        /** Only probe when panel URL is unset or would be wrong — respect explicit MANAGED_AGENT_RUNNER_PUBLIC_URL */
        let detected = null;
        if (explicitPublicUrl === '' && !routableEnvPip) {
            detected = await detectPublicIpv4ForRunner();
        }

        if (routableEnvPip) {
            heartbeatPayload.public_ip = routableEnvPip;
        } else if (detected) {
            heartbeatPayload.public_ip = detected;
        }

        if (explicitPublicUrl !== '') {
            heartbeatPayload.runner_url = explicitPublicUrl;
        } else if (routableEnvPip) {
            heartbeatPayload.runner_url = `http://${routableEnvPip}:${port}`;
        } else if (detected) {
            heartbeatPayload.runner_url = `http://${detected}:${port}`;
        }

        const displayName = envPair('MANAGED_AGENT_SERVER_NAME', 'RELEASEPANEL_SERVER_NAME', '');
        if (displayName) {
            heartbeatPayload.name = displayName;
        }

        const response = await panelFetchJson('/api/runner-heartbeat', {
            method: 'POST',
            bodyObj: heartbeatPayload,
        });

        appendLog({
            event: 'heartbeat',
            action: 'heartbeat',
            success: response.ok,
            status_code: response.status,
            ...(response.ok
                ? {}
                : {
                      auth_code: response.json?.code ?? null,
                      message: response.json?.message ?? null,
                      hint: response.json?.hint ?? null,
                  }),
        });
        if (!response.ok) {
            maybePanelOnboardingRejectedConsoleHint('/api/runner-heartbeat', response);
        }
    } catch (error) {
        appendLog({
            event: 'heartbeat',
            action: 'heartbeat',
            success: false,
            message: error.message,
        });
    }
}

function requestApiKey(request) {
    return request.get('X-Managed-Agent-Key') || request.get('X-RELEASEPANEL-KEY');
}

function requireApiKey(request, response, next) {
    if (requestApiKey(request) !== apiKey) {
        appendLog({
            method: request.method,
            path: request.path,
            requester_ip: requesterIp(request),
            success: false,
            duration_ms: 0,
            message: 'unauthorized',
        });

        response.status(401).json({
            success: false,
            exit_code: 1,
            stdout: '',
            stderr: 'Unauthorized',
            duration_ms: 0,
        });
        return;
    }

    next();
}

function validateSiteEnv(request, response, next) {
    const site = request.params.site;
    const env = request.params.env;

    if (!isSafeSlug(site) || !isSafeSlug(env)) {
        response.status(400).json({
            success: false,
            exit_code: 1,
            stdout: '',
            stderr: `Invalid site/environment: ${site}/${env}`,
            duration_ms: 0,
        });
        return;
    }

    const cfgPath = siteConfigPath(site, env);
    if (siteToolkitEnvWeak(cfgPath)) {
        console.error(`[managed-deploy-agent] No usable toolkit site env at ${cfgPath} (missing or empty) — proceeding (deploy may use panel-injected env).`);
    }

    next();
}

function validatePromote(request, response, next) {
    const { site, fromEnv, toEnv } = request.params;

    if (!isSafeSlug(site) || !isSafeSlug(fromEnv) || !isSafeSlug(toEnv) || fromEnv === toEnv) {
        response.status(400).json({
            success: false,
            exit_code: 1,
            stdout: '',
            stderr: `Invalid promote request: ${site}/${fromEnv} -> ${toEnv}`,
            duration_ms: 0,
        });
        return;
    }

    const fromPath = siteConfigPath(site, fromEnv);
    const toPath = siteConfigPath(site, toEnv);
    if (siteToolkitEnvWeak(fromPath) || siteToolkitEnvWeak(toPath)) {
        console.error(`[managed-deploy-agent] Missing or empty toolkit env for promote (${site} ${fromEnv}→${toEnv}); continuing.`);
    }

    next();
}

/**
 * Single URL path segment for site or env slug (also used in sites/site/env compound keys).
 * Allows dots for domain-style slugs; rejects empty, "..", and overlong values.
 */
function isSafeSlug(value) {
    if (typeof value !== 'string' || value === '') {
        return false;
    }
    if (value.length > 80 || value.includes('..')) {
        return false;
    }
    return /^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$/.test(value) || /^[A-Za-z0-9]$/.test(value);
}

/**
 * Path-safe segment for GET/PUT /env/:site/:env only.
 * Looser than {@link isSafeSlug} so legitimate panel slugs are not rejected with HTTP 400,
 * while still blocking traversal and control characters.
 */
function isEnvRouteSegment(value) {
    if (typeof value !== 'string' || value === '' || value.length > 128) {
        return false;
    }
    if (value.includes('..') || /[\0\/\\]/.test(value)) {
        return false;
    }

    return true;
}

/**
 * Opt-in: set MANAGED_AGENT_DEBUG_ENV_REQUEST=1 (or RELEASEPANEL_DEBUG_ENV_REQUEST=1) to log
 * Content-Type, body shape, and route segments for GET/PUT /env/:site/:env before handlers run.
 */
function debugEnvRequestMiddleware(request, response, next) {
    if (!envTruthy('MANAGED_AGENT_DEBUG_ENV_REQUEST', 'RELEASEPANEL_DEBUG_ENV_REQUEST')) {
        next();
        return;
    }

    const body = request.body;
    let bodyPreview = '';
    try {
        if (body === undefined) {
            bodyPreview = '(undefined)';
        } else if (body === null) {
            bodyPreview = '(null)';
        } else if (typeof body === 'string') {
            bodyPreview = body.slice(0, 200);
        } else {
            bodyPreview = JSON.stringify(body).slice(0, 200);
        }
    } catch (err) {
        bodyPreview = `(preview_error: ${err.message || err})`;
    }

    console.error('[managed-deploy-agent] env.request', {
        method: request.method,
        path: request.originalUrl || request.url,
        routeSite: request.params.site,
        routeEnv: request.params.env,
        contentType: request.headers['content-type'],
        contentLength: request.headers['content-length'],
        bodyType: typeof body,
        bodyPreview,
    });

    next();
}

function validateEnvSitePath(request, response, next) {
    const site = request.params.site;
    const env = request.params.env;

    if (!isEnvRouteSegment(site) || !isEnvRouteSegment(env)) {
        if (envTruthy('MANAGED_AGENT_DEBUG_ENV_REQUEST', 'RELEASEPANEL_DEBUG_ENV_REQUEST')) {
            console.error('[managed-deploy-agent] env.error invalid_route_segments', {
                site,
                env,
                siteOk: isEnvRouteSegment(site),
                envOk: isEnvRouteSegment(env),
            });
        }
        response.status(400).json({
            success: false,
            exit_code: 1,
            stdout: '',
            stderr: `Invalid site/environment: ${site}/${env}`,
            duration_ms: 0,
            error: 'invalid_env_route_segments',
            site,
            environment: env,
        });
        return;
    }

    next();
}

function sharedEnvPath(env) {
    return `${environmentBasePath(env)}/shared/.env`;
}

function envBackupPath(env) {
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, 'Z');

    return `${environmentBasePath(env)}/shared/.env.backups/.env.${stamp}`;
}

function resolveSiteToolkitEnvPath(envKey) {
    if (!toolkitPath || !fs.existsSync(toolkitPath)) {
        return null;
    }

    if (envKey.includes('/') && envKey.split('/').filter(Boolean).length === 2) {
        const [site, envSlug] = envKey.split('/', 2);
        if (isSafeSlug(site) && isSafeSlug(envSlug)) {
            const candidate = path.join(toolkitPath, 'sites', site, `${envSlug}.env`);

            return fs.existsSync(candidate) ? candidate : null;
        }

        return null;
    }

    const sitesRoot = path.join(toolkitPath, 'sites');
    if (!fs.existsSync(sitesRoot)) {
        return null;
    }

    const siteDirs = fs.readdirSync(sitesRoot, { withFileTypes: true }).filter((d) => d.isDirectory());
    for (const dirent of siteDirs) {
        const siteSlug = dirent.name;
        if (!isSafeSlug(siteSlug)) {
            continue;
        }

        const dir = path.join(sitesRoot, siteSlug);
        let files = [];
        try {
            files = fs.readdirSync(dir);
        } catch {
            continue;
        }

        for (const file of files) {
            if (!file.endsWith('.env')) {
                continue;
            }

            const envSlug = file.slice(0, -'.env'.length);
            if (!isSafeSlug(envSlug)) {
                continue;
            }

            if (`${siteSlug}-${envSlug}` === envKey) {
                return path.join(dir, file);
            }
        }
    }

    return null;
}

function deployConfigPath(env) {
    const legacyPath = path.join(toolkitPath, `deploy.${env}.env`);
    if (fs.existsSync(legacyPath)) {
        return legacyPath;
    }

    const resolved = resolveSiteToolkitEnvPath(env);
    if (resolved) {
        return resolved;
    }

    return legacyPath;
}

function siteConfigPath(site, env) {
    return path.join(toolkitPath, 'sites', site, `${env}.env`);
}

/** True when file is missing, not a file, empty, or unreadable — matches bash __rp_site_toolkit_env_unusable */
function siteToolkitEnvWeak(p) {
    try {
        if (!fs.existsSync(p)) {
            return true;
        }
        const st = fs.statSync(p);
        if (!st.isFile() || st.size === 0) {
            return true;
        }
        fs.accessSync(p, fs.constants.R_OK);
    } catch {
        return true;
    }
    return false;
}

function listSiteConfigs() {
    const root = path.join(toolkitPath, 'sites');
    const sites = [];

    if (!fs.existsSync(root)) {
        return sites;
    }

    for (const site of fs.readdirSync(root, { withFileTypes: true }).filter((entry) => entry.isDirectory())) {
        if (!isSafeSlug(site.name)) {
            continue;
        }

        const sitePath = path.join(root, site.name);
        const environments = fs.readdirSync(sitePath, { withFileTypes: true })
            .filter((entry) => entry.isFile() && entry.name.endsWith('.env'))
            .map((entry) => entry.name.replace(/\.env$/, ''))
            .filter(isSafeSlug);

        sites.push({
            slug: site.name,
            environments,
        });
    }

    return sites;
}

function scriptPath(script) {
    return path.join(toolkitPath, 'scripts', script);
}

function siteCommandArgs(actionName, site, env) {
    const generic = {
        status: 'site-status.sh',
        deploy: 'site-deploy.sh',
        rollback: 'site-rollback.sh',
        repair: 'site-repair.sh',
        nginx: 'site-nginx.sh',
        ssl: 'site-ssl.sh',
        workers: 'site-workers.sh',
        smoke: 'site-smoke.sh',
        logs: 'site-logs.sh',
        deployKey: 'site-deploy-key.sh',
    };
    const args = [scriptPath(generic[actionName]), site, env];

    return {
        command: '/bin/bash',
        args,
    };
}

function deployConfigBackupPath(env) {
    const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..+$/, 'Z');
    const programKey = deployProgramKey(env);

    return path.join(toolkitPath, '.deploy-env.backups', `deploy.${programKey}.env.${stamp}`);
}

function environmentBasePath(env) {
    return deployConfig(env).RELEASEPANEL_BASE || `/var/www/sites/${env}`;
}

function fixedLogTargets(env) {
    const programKey = deployProgramKey(env);

    return {
        deploy: `/var/log/releasepanel-${programKey}-deploy.log`,
        nginx_error: `/var/log/nginx/releasepanel-${programKey}-error.log`,
        nginx_access: `/var/log/nginx/releasepanel-${programKey}-access.log`,
        laravel: `${environmentBasePath(env)}/shared/storage/logs/laravel.log`,
        worker_default: `${environmentBasePath(env)}/shared/storage/logs/worker-default.log`,
        worker_heavy: `${environmentBasePath(env)}/shared/storage/logs/worker-heavy.log`,
        worker_notifications: `${environmentBasePath(env)}/shared/storage/logs/worker-notifications.log`,
        horizon: `${environmentBasePath(env)}/shared/storage/logs/horizon.log`,
        runner: logPath,
    };
}

function cronPath(env) {
    const programKey = deployProgramKey(env);

    return `/etc/cron.d/releasepanel-${programKey}-scheduler`;
}

function parseEnvFile(filePath) {
    if (!fs.existsSync(filePath)) {
        return {};
    }

    return fs.readFileSync(filePath, 'utf8')
        .split(/\r?\n/)
        .reduce((values, line) => {
            const trimmed = line.trim();

            if (trimmed === '' || trimmed.startsWith('#') || !trimmed.includes('=')) {
                return values;
            }

            const [key, ...parts] = trimmed.split('=');
            values[key] = parts.join('=').replace(/^['"]|['"]$/g, '');

            return values;
        }, {});
}

function normalizeDeployConfig(config) {
    const siteSlug = config.SITE_SLUG || config.RELEASEPANEL_SITE_SLUG || 'site';
    const envSlug = config.ENV_SLUG || config.RELEASEPANEL_ENV_SLUG || 'env';
    const releasepanelEnv = config.RELEASEPANEL_ENV || `${siteSlug}-${envSlug}`;

    return {
        ...config,
        RELEASEPANEL_SITE_SLUG: siteSlug,
        RELEASEPANEL_ENV_SLUG: envSlug,
        RELEASEPANEL_ENV: releasepanelEnv,
        RELEASEPANEL_NGINX_SITE_BASENAME: config.RELEASEPANEL_NGINX_SITE_BASENAME || releasepanelEnv,
        RELEASEPANEL_APP_USER: config.RELEASEPANEL_APP_USER || config.APP_USER || 'laravel',
        RELEASEPANEL_FILE_GROUP: config.RELEASEPANEL_FILE_GROUP || config.FILE_GROUP || 'www-data',
        RELEASEPANEL_REPO: config.RELEASEPANEL_REPO || config.REPO_URL || '',
        RELEASEPANEL_BRANCH: config.RELEASEPANEL_BRANCH || config.BRANCH || 'main',
        RELEASEPANEL_SERVER_NAME: config.RELEASEPANEL_SERVER_NAME || config.DOMAIN || '',
        RELEASEPANEL_BASE: config.RELEASEPANEL_BASE || config.BASE_PATH || `/var/www/sites/${siteSlug}/${envSlug}`,
        RELEASEPANEL_PHP_VERSION: config.RELEASEPANEL_PHP_VERSION || config.PHP_VERSION || '',
        RELEASEPANEL_HEALTH_PATH: config.RELEASEPANEL_HEALTH_PATH || config.HEALTH_PATH || '/up',
        RELEASEPANEL_WORKER_MODE: config.RELEASEPANEL_WORKER_MODE || config.WORKER_MODE || 'queue',
    };
}

function deployConfig(env) {
    return normalizeDeployConfig(parseEnvFile(deployConfigPath(env)));
}

function deployProgramKey(env) {
    const cfg = deployConfig(env);

    return cfg.RELEASEPANEL_ENV || String(env).replace(/\//g, '-');
}

function runCurrentArtisan(env, args, timeoutMs = 15000) {
    const currentPath = currentReleasePath(env);
    const config = deployConfig(env);
    const appUser = config.RELEASEPANEL_APP_USER || 'laravel';

    if (!fs.existsSync(`${currentPath}/artisan`)) {
        return {
            installed: false,
            success: false,
            stdout: '',
            stderr: `${currentPath}/artisan does not exist.`,
            exit_code: 1,
        };
    }

    const result = spawnSync('sudo', ['-Hu', appUser, 'php', 'artisan', ...args], {
        cwd: currentPath,
        encoding: 'utf8',
        timeout: timeoutMs,
    });

    return {
        installed: true,
        success: result.status === 0,
        stdout: result.stdout || '',
        stderr: result.stderr || result.error?.message || '',
        exit_code: typeof result.status === 'number' ? result.status : 1,
    };
}

function horizonSummary(env) {
    const currentPath = currentReleasePath(env);

    if (!fs.existsSync(`${currentPath}/config/horizon.php`)) {
        return {
            installed: false,
            status: 'not_installed',
            message: 'Horizon not installed',
        };
    }

    const status = runCurrentArtisan(env, ['horizon:status']);
    const failed = runCurrentArtisan(env, ['queue:failed'], 20000);

    return {
        installed: true,
        status: status.success ? 'available' : 'attention',
        message: (status.stdout || status.stderr || 'Horizon status checked.').trim(),
        failed_jobs_count: failed.success
            ? failed.stdout.split(/\r?\n/).filter((line) => line.trim() !== '' && !line.includes('UUID')).length
            : null,
    };
}

function certificateSummary(env) {
    const config = deployConfig(env);
    const serverName = config.RELEASEPANEL_SERVER_NAME || '';
    const serverAliases = (config.RELEASEPANEL_SERVER_ALIASES || '').split(/\s+/).filter(Boolean);
    const nginxBasename = config.RELEASEPANEL_NGINX_SITE_BASENAME || config.RELEASEPANEL_ENV || '';
    const finalEnabledPath = nginxBasename ? `/etc/nginx/sites-enabled/${nginxBasename}-https.conf` : '';
    const acmeEnabledPath = nginxBasename ? `/etc/nginx/sites-enabled/${nginxBasename}-acme.conf` : '';
    const finalEnabled = Boolean(nginxBasename && fs.existsSync(finalEnabledPath));
    const acmeEnabled = Boolean(nginxBasename && fs.existsSync(acmeEnabledPath));

    if (serverName === '') {
        return {
            status: 'unknown',
            ssl_state: 'unknown',
            message: 'RELEASEPANEL_SERVER_NAME is not set.',
        };
    }

    const certPathLe = `/etc/letsencrypt/live/${serverName}/fullchain.pem`;
    let certPath = certPathLe;
    let certExists = fs.existsSync(certPathLe);

    let sslState = 'missing';

    if (certExists && finalEnabled && !acmeEnabled) {
        sslState = 'active';
    } else if (!finalEnabled && acmeEnabled) {
        sslState = 'acme_only';
    } else if (certExists && finalEnabled && acmeEnabled) {
        sslState = 'misconfigured';
    } else if (certExists && !finalEnabled) {
        sslState = 'misconfigured';
    }

    if (!certExists) {
        return {
            status: sslState,
            ssl_state: sslState,
            server_name: serverName,
            server_aliases: serverAliases,
            path: certPathLe,
            nginx: {
                final_enabled: finalEnabled,
                final_enabled_path: finalEnabledPath,
                acme_enabled: acmeEnabled,
                acme_enabled_path: acmeEnabledPath,
            },
            expires_at: null,
        };
    }

    const result = spawnSync('openssl', ['x509', '-enddate', '-noout', '-in', certPath], {
        encoding: 'utf8',
        timeout: 10000,
    });
    const expiresAt = result.status === 0
        ? (result.stdout || '').replace('notAfter=', '').trim()
        : null;

    return {
        status: result.status === 0 ? sslState : 'attention',
        ssl_state: result.status === 0 ? sslState : 'attention',
        server_name: serverName,
        server_aliases: serverAliases,
        path: certPath,
        nginx: {
            final_enabled: finalEnabled,
            final_enabled_path: finalEnabledPath,
            acme_enabled: acmeEnabled,
            acme_enabled_path: acmeEnabledPath,
        },
        expires_at: expiresAt,
        message: result.status === 0 ? `Certificate found; nginx state is ${sslState}.` : (result.stderr || 'Unable to inspect certificate.').trim(),
    };
}

function httpsCheckSummary(env) {
    const config = deployConfig(env);
    const serverName = config.RELEASEPANEL_SERVER_NAME || '';
    const configuredPath = config.RELEASEPANEL_HEALTH_PATH || '/up';
    const paths = [...new Set([configuredPath, '/health', '/'].filter(Boolean))];

    if (serverName === '') {
        return {
            success: false,
            status: 'unknown',
            status_code: null,
            message: 'RELEASEPANEL_SERVER_NAME is not set.',
        };
    }

    const attempts = paths.map((pathName) => {
        const result = spawnSync('curl', [
            '-k',
            '-s',
            '-o',
            '/dev/null',
            '-w',
            '%{http_code}',
            '--max-time',
            '10',
            '--resolve',
            `${serverName}:443:127.0.0.1`,
            `https://${serverName}${pathName}`,
        ], {
            encoding: 'utf8',
            timeout: 15000,
        });

        return {
            path: pathName,
            url: `https://${serverName}${pathName}`,
            status_code: Number.parseInt((result.stdout || '').trim(), 10),
            exit_code: typeof result.status === 'number' ? result.status : 1,
            stderr: (result.stderr || '').trim(),
        };
    });
    const successfulAttempt = attempts.find((attempt) => attempt.exit_code === 0 && [200, 302].includes(attempt.status_code));
    const lastAttempt = attempts[attempts.length - 1] || null;
    const success = Boolean(successfulAttempt);

    return {
        success,
        status: success ? 'active' : 'failing',
        status_code: successfulAttempt
            ? successfulAttempt.status_code
            : (Number.isFinite(lastAttempt?.status_code) ? lastAttempt.status_code : null),
        server_name: serverName,
        url: successfulAttempt?.url || lastAttempt?.url || null,
        attempts,
        message: success
            ? `HTTPS health returned ${successfulAttempt.status_code} at ${successfulAttempt.path}.`
            : (lastAttempt?.stderr || `HTTPS health checks failed; last response was ${Number.isFinite(lastAttempt?.status_code) ? lastAttempt.status_code : 'no response'}.`).trim(),
    };
}

function phpFpmSummary(env) {
    const config = deployConfig(env);
    const phpVersion = config.RELEASEPANEL_PHP_VERSION || '';
    const configuredSocketPath = phpVersion === '' ? '' : `/run/php/php${phpVersion}-fpm.sock`;
    const exists = configuredSocketPath !== '' && fs.existsSync(configuredSocketPath);

    return {
        ok: exists,
        status: exists ? 'ok' : 'missing',
        socket: exists ? configuredSocketPath : null,
        configured_socket: configuredSocketPath || null,
        message: exists ? 'PHP-FPM socket found.' : `PHP-FPM socket missing at ${configuredSocketPath || 'configured path'}.`,
    };
}

function nginxStateSummary(env, sslSummary) {
    const result = spawnSync('nginx', ['-t'], {
        encoding: 'utf8',
        timeout: 10000,
    });
    const finalEnabled = Boolean(sslSummary.nginx?.final_enabled);
    const acmeEnabled = Boolean(sslSummary.nginx?.acme_enabled);
    const valid = result.status === 0 && finalEnabled && !acmeEnabled;

    return {
        ok: valid,
        status: valid ? 'valid' : 'invalid',
        config_test_ok: result.status === 0,
        final_enabled: finalEnabled,
        final_enabled_path: sslSummary.nginx?.final_enabled_path || null,
        acme_enabled: acmeEnabled,
        acme_enabled_path: sslSummary.nginx?.acme_enabled_path || null,
        message: valid
            ? 'Final HTTPS nginx config is active.'
            : (result.stderr || result.stdout || 'Nginx is not in final HTTPS state.').trim(),
    };
}

function workersSummary(env) {
    const result = spawnSync('supervisorctl', ['status'], {
        encoding: 'utf8',
        timeout: 10000,
    });

    if (result.status !== 0) {
        return {
            ok: false,
            status: 'stopped',
            programs: [],
            message: (result.stderr || 'Unable to read supervisor status.').trim(),
        };
    }

    const prefix = `releasepanel-${deployProgramKey(env)}-`;
    const programs = (result.stdout || '')
        .split(/\r?\n/)
        .map((line) => line.trim())
        .filter((line) => line.startsWith(prefix))
        .map((line) => ({
            name: line.split(/\s+/)[0],
            raw: line,
            running: /\sRUNNING\s/.test(line),
        }));
    const ok = programs.length > 0 && programs.every((program) => program.running);

    return {
        ok,
        status: ok ? 'running' : 'stopped',
        programs,
        message: ok ? 'Supervisor workers are running.' : 'Supervisor workers are missing or stopped.',
    };
}

function schedulerSummary(env) {
    const cron = statSummary(cronPath(env));

    return {
        ok: cron.exists,
        status: cron.exists ? 'ok' : 'missing',
        cron,
        message: cron.exists ? 'Scheduler cron is present.' : 'Scheduler cron is missing.',
    };
}

function environmentHealthSummary(env) {
    const ssl = certificateSummary(env);
    const https = httpsCheckSummary(env);
    const nginx = nginxStateSummary(env, ssl);
    const phpFpm = phpFpmSummary(env);
    const workers = workersSummary(env);
    const scheduler = schedulerSummary(env);
    const sslPresent = ssl.status === 'active';
    const healthy = https.success
        && sslPresent
        && nginx.ok
        && phpFpm.ok
        && workers.ok
        && scheduler.ok;

    return {
        success: healthy,
        overall: healthy ? 'healthy' : 'unhealthy',
        https: https.success,
        ssl: sslPresent ? 'present' : (ssl.status || 'missing'),
        nginx: nginx.status,
        php_fpm: phpFpm.status,
        workers: workers.status,
        scheduler: scheduler.status,
        details: {
            https,
            ssl,
            nginx,
            php_fpm: phpFpm,
            workers,
            scheduler,
        },
    };
}

function statSummary(filePath) {
    if (!fs.existsSync(filePath)) {
        return {
            exists: false,
            path: filePath,
        };
    }

    const stat = fs.statSync(filePath);

    return {
        exists: true,
        path: filePath,
        size_bytes: stat.size,
        modified_at: stat.mtime.toISOString(),
    };
}

function tailFile(filePath, lineCount) {
    const stat = fs.statSync(filePath);
    const start = Math.max(0, stat.size - maxTailBytes);
    const buffer = Buffer.alloc(stat.size - start);
    const fd = fs.openSync(filePath, 'r');

    try {
        fs.readSync(fd, buffer, 0, buffer.length, start);
    } finally {
        fs.closeSync(fd);
    }

    return buffer.toString('utf8').split(/\r?\n/).slice(-lineCount).join('\n');
}

function backupDirectoryTargets(env) {
    return {
        shared_env: `${environmentBasePath(env)}/shared/.env.backups`,
        deploy_config: path.join(toolkitPath, '.deploy-env.backups'),
    };
}

function listDirectoryFiles(directoryPath, prefix = '') {
    if (!fs.existsSync(directoryPath)) {
        return [];
    }

    return fs.readdirSync(directoryPath)
        .filter((name) => prefix === '' || name.startsWith(prefix))
        .map((name) => {
            const filePath = path.join(directoryPath, name);
            const stat = fs.statSync(filePath);

            if (!stat.isFile()) {
                return null;
            }

            return {
                name,
                path: filePath,
                size_bytes: stat.size,
                modified_at: stat.mtime.toISOString(),
            };
        })
        .filter(Boolean)
        .sort((a, b) => b.modified_at.localeCompare(a.modified_at))
        .slice(0, 25);
}

function currentReleasePath(env) {
    return `${environmentBasePath(env)}/current`;
}

function clearLaravelCaches(env) {
    const currentPath = currentReleasePath(env);

    if (!fs.existsSync(`${currentPath}/artisan`)) {
        return {
            success: false,
            message: `${currentPath}/artisan does not exist; deploy before clearing caches.`,
        };
    }

    const result = spawnSync('sudo', ['-Hu', (parseEnvFile(deployConfigPath(env)).RELEASEPANEL_APP_USER || 'laravel'), 'php', 'artisan', 'optimize:clear'], {
        cwd: currentPath,
        encoding: 'utf8',
        timeout: 60000,
    });

    if (result.error) {
        return {
            success: false,
            message: result.error.message,
        };
    }

    return {
        success: result.status === 0,
        message: result.status === 0
            ? 'Laravel caches cleared.'
            : (result.stderr || result.stdout || `optimize:clear exited ${result.status}`).trim(),
    };
}

/** When set, log resolved Laravel shared .env path for GET/PUT /env (readSharedEnv / writeSharedEnv). */
function logEnvPathDebug(phase, envKey, filePath) {
    if (!envTruthy('MANAGED_AGENT_LOG_ENV_PATH', 'RELEASEPANEL_LOG_ENV_PATH')) {
        return;
    }
    let exists = false;
    try {
        exists = fs.existsSync(filePath);
    } catch (_) {
        exists = false;
    }
    console.error(`[managed-deploy-agent] env.${phase} envKey=${envKey} path=${filePath} exists=${exists}`);
}

function readSharedEnv(request, response) {
    const env = request.params.env;
    const filePath = sharedEnvPath(env);
    logEnvPathDebug('read', env, filePath);
    const startedAt = Date.now();

    fs.readFile(filePath, 'utf8', (error, contents) => {
        const durationMs = Date.now() - startedAt;

        if (error) {
            // Missing shared/.env is normal before first deploy — panel expects HTTP 2xx + success + empty contents.
            if (error.code === 'ENOENT') {
                appendLog({
                    method: request.method,
                    path: request.path,
                    env,
                    action: 'env.read',
                    requester_ip: requesterIp(request),
                    success: true,
                    duration_ms: durationMs,
                    message: 'shared .env not created yet (ok)',
                });

                response.json({
                    success: true,
                    environment: env,
                    path: filePath,
                    contents: '',
                });
                return;
            }

            appendLog({
                method: request.method,
                path: request.path,
                env,
                action: 'env.read',
                requester_ip: requesterIp(request),
                success: false,
                duration_ms: durationMs,
                message: error.message,
            });

            response.status(500).json({
                success: false,
                message: error.message,
                path: filePath,
            });
            return;
        }

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'env.read',
            requester_ip: requesterIp(request),
            success: true,
            duration_ms: durationMs,
        });

        response.json({
            success: true,
            environment: env,
            path: filePath,
            contents,
        });
    });
}

function writeSharedEnv(request, response) {
    const env = request.params.env;
    const filePath = sharedEnvPath(env);
    logEnvPathDebug('write', env, filePath);

    const body = request.body;
    let contents;
    if (body == null || typeof body !== 'object') {
        contents = '';
    } else if (!Object.prototype.hasOwnProperty.call(body, 'contents')) {
        contents = '';
    } else {
        const raw = body.contents;
        if (raw === undefined || raw === null) {
            contents = '';
        } else if (typeof raw === 'string') {
            contents = raw;
        } else {
            response.status(422).json({
                success: false,
                message: 'contents must be a string.',
                error: 'contents_not_string',
            });
            return;
        }
    }

    const startedAt = Date.now();

    if (contents.length > 128 * 1024) {
        response.status(413).json({
            success: false,
            message: '.env content is too large.',
            error: 'contents_too_large',
        });
        return;
    }

    if (contents.includes('\0')) {
        response.status(422).json({
            success: false,
            message: '.env content cannot contain null bytes.',
            error: 'contents_null_byte',
        });
        return;
    }

    if (envTruthy('MANAGED_AGENT_DEBUG_ENV_REQUEST', 'RELEASEPANEL_DEBUG_ENV_REQUEST')) {
        console.error('[managed-deploy-agent] env.write.accepted', {
            envKey: env,
            path: filePath,
            contentsChars: contents.length,
            bodyHadContentsKey: body != null && typeof body === 'object' && Object.prototype.hasOwnProperty.call(body, 'contents'),
        });
    }

    try {
        fs.mkdirSync(path.join(environmentBasePath(env), 'shared', '.env.backups'), { recursive: true });

        const stat = fs.existsSync(filePath) ? fs.statSync(filePath) : null;
        const backupPath = envBackupPath(env);

        if (stat) {
            fs.copyFileSync(filePath, backupPath);
            fs.chmodSync(backupPath, stat.mode);
            fs.chownSync(backupPath, stat.uid, stat.gid);
        }

        const tmpPath = `${filePath}.tmp.${process.pid}`;
        fs.writeFileSync(tmpPath, contents.endsWith('\n') ? contents : `${contents}\n`, { mode: stat?.mode ?? 0o660 });

        if (stat) {
            fs.chownSync(tmpPath, stat.uid, stat.gid);
        }

        fs.renameSync(tmpPath, filePath);

        const cacheClear = clearLaravelCaches(env);

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'env.write',
            requester_ip: requesterIp(request),
            success: cacheClear.success,
            duration_ms: Date.now() - startedAt,
            message: `${stat ? `Backup: ${backupPath}` : 'Created new shared .env'}; ${cacheClear.message}`,
        });

        response.json({
            success: true,
            environment: env,
            path: filePath,
            backup_path: stat ? backupPath : null,
            cache_cleared: cacheClear.success,
            message: `${stat ? `Saved. Backup created at ${backupPath}.` : 'Saved new shared .env.'} ${cacheClear.message}`,
        });
    } catch (error) {
        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'env.write',
            requester_ip: requesterIp(request),
            success: false,
            duration_ms: Date.now() - startedAt,
            message: error.message,
        });

        response.status(500).json({
            success: false,
            message: error.message,
            path: filePath,
        });
    }
}

function readDeployConfig(request, response) {
    const env = request.params.env;
    const filePath = deployConfigPath(env);
    const startedAt = Date.now();

    fs.readFile(filePath, 'utf8', (error, contents) => {
        const durationMs = Date.now() - startedAt;

        if (error) {
            appendLog({
                method: request.method,
                path: request.path,
                env,
                action: 'deploy-config.read',
                requester_ip: requesterIp(request),
                success: false,
                duration_ms: durationMs,
                message: error.message,
            });

            response.status(error.code === 'ENOENT' ? 404 : 500).json({
                success: false,
                message: error.code === 'ENOENT' ? `${filePath} does not exist.` : error.message,
                path: filePath,
            });
            return;
        }

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'deploy-config.read',
            requester_ip: requesterIp(request),
            success: true,
            duration_ms: durationMs,
        });

        response.json({
            success: true,
            environment: env,
            path: filePath,
            contents,
        });
    });
}

function writeDeployConfig(request, response) {
    const env = request.params.env;
    const filePath = deployConfigPath(env);
    const contents = request.body?.contents;
    const startedAt = Date.now();

    if (typeof contents !== 'string') {
        response.status(422).json({
            success: false,
            message: 'contents must be a string.',
        });
        return;
    }

    if (contents.length > 64 * 1024) {
        response.status(413).json({
            success: false,
            message: 'Deploy config content is too large.',
        });
        return;
    }

    if (contents.includes('\0')) {
        response.status(422).json({
            success: false,
            message: 'Deploy config content cannot contain null bytes.',
        });
        return;
    }

    try {
        fs.mkdirSync(path.join(toolkitPath, '.deploy-env.backups'), { recursive: true });

        const stat = fs.existsSync(filePath) ? fs.statSync(filePath) : null;
        const backupPath = deployConfigBackupPath(env);

        if (stat) {
            fs.copyFileSync(filePath, backupPath);
            fs.chmodSync(backupPath, stat.mode);
            fs.chownSync(backupPath, stat.uid, stat.gid);
        }

        const tmpPath = `${filePath}.tmp.${process.pid}`;
        fs.writeFileSync(tmpPath, contents.endsWith('\n') ? contents : `${contents}\n`, { mode: stat?.mode ?? 0o640 });

        if (stat) {
            fs.chownSync(tmpPath, stat.uid, stat.gid);
        }

        fs.renameSync(tmpPath, filePath);

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'deploy-config.write',
            requester_ip: requesterIp(request),
            success: true,
            duration_ms: Date.now() - startedAt,
            message: stat ? `Backup: ${backupPath}` : 'Created new deploy config.',
        });

        response.json({
            success: true,
            environment: env,
            path: filePath,
            backup_path: stat ? backupPath : null,
            message: stat ? `Saved. Backup created at ${backupPath}.` : 'Saved new deploy config.',
        });
    } catch (error) {
        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: 'deploy-config.write',
            requester_ip: requesterIp(request),
            success: false,
            duration_ms: Date.now() - startedAt,
            message: error.message,
        });

        response.status(500).json({
            success: false,
            message: error.message,
            path: filePath,
        });
    }
}

function readOpsStatus(request, response) {
    const env = request.params.env;
    const basePath = environmentBasePath(env);
    const currentPath = `${basePath}/current`;
    const deployJsonPath = `${basePath}/shared/deploy.json`;
    const logs = fixedLogTargets(env);

    response.json({
        success: true,
        environment: env,
        server: {
            hostname: os.hostname(),
            uptime_seconds: Math.round(os.uptime()),
            load_average: os.loadavg(),
            memory: {
                total_bytes: os.totalmem(),
                free_bytes: os.freemem(),
            },
        },
        paths: {
            base: statSummary(basePath),
            current: statSummary(currentPath),
            deploy_json: statSummary(deployJsonPath),
            shared_env: statSummary(sharedEnvPath(env)),
            deploy_config: statSummary(deployConfigPath(env)),
        },
        scheduler: {
            cron: statSummary(cronPath(env)),
            last_heartbeat: null,
            message: 'Scheduler heartbeat is not tracked yet.',
        },
        ssl: certificateSummary(env),
        https_check: httpsCheckSummary(env),
        health: environmentHealthSummary(env),
        horizon: horizonSummary(env),
        logs: Object.fromEntries(Object.entries(logs).map(([key, filePath]) => [key, statSummary(filePath)])),
    });
}

function readEnvironmentHealth(request, response) {
    const env = request.params.env;
    const summary = environmentHealthSummary(env);

    response.status(summary.success ? 200 : 500).json({
        environment: env,
        ...summary,
    });
}

function readHttpsCheck(request, response) {
    const env = request.params.env;
    const summary = httpsCheckSummary(env);

    response.status(summary.success ? 200 : 500).json({
        environment: env,
        ...summary,
    });
}

function readOpsLog(request, response) {
    const env = request.params.env;
    const logKey = request.params.log;
    const targets = fixedLogTargets(env);
    const filePath = targets[logKey];
    const requestedLines = Number.parseInt(request.query.lines || '200', 10);
    const lineCount = Number.isFinite(requestedLines) ? Math.max(20, Math.min(500, requestedLines)) : 200;

    if (!filePath) {
        response.status(404).json({
            success: false,
            message: `Unknown log target: ${logKey}`,
        });
        return;
    }

    try {
        response.json({
            success: true,
            environment: env,
            log: logKey,
            path: filePath,
            lines: lineCount,
            contents: tailFile(filePath, lineCount),
        });
    } catch (error) {
        response.status(error.code === 'ENOENT' ? 404 : 500).json({
            success: false,
            environment: env,
            log: logKey,
            path: filePath,
            message: error.code === 'ENOENT' ? `${filePath} does not exist.` : error.message,
        });
    }
}

function readOpsBackups(request, response) {
    const env = request.params.env;
    const targets = backupDirectoryTargets(env);
    const programKey = deployProgramKey(env);

    response.json({
        success: true,
        environment: env,
        backups: {
            shared_env: listDirectoryFiles(targets.shared_env),
            deploy_config: listDirectoryFiles(targets.deploy_config, `deploy.${programKey}.env.`),
        },
    });
}

function siteActionDefinition(actionName) {
    const resolvedAction = actionAliases[actionName] || actionName;

    return {
        actionName: resolvedAction,
        definition: siteActions[resolvedAction],
    };
}

function commandSpec(definition, ...args) {
    const value = definition.args(...args);

    if (Array.isArray(value)) {
        throw new Error('Runner actions must return explicit command specs.');
    }

    return value;
}

function appendRunOutput(run, stream, chunk) {
    run[stream] += chunk.toString();

    if (run[stream].length > maxRunOutputBytes) {
        run[stream] = run[stream].slice(-maxRunOutputBytes);
    }
}

function commandRunPayload(run) {
    const status = run.running ? 'running' : (run.success ? 'success' : 'failed');

    return {
        success: run.success,
        run_id: run.id,
        job_id: run.id,
        status,
        site: run.site || null,
        environment: run.environment,
        from_environment: run.fromEnvironment || null,
        action: run.action,
        running: run.running,
        started_at: run.startedAt,
        finished_at: run.finishedAt,
        exit_code: run.exitCode,
        stdout: run.stdout,
        stderr: run.stderr,
        duration_ms: run.finishedAt ? (Date.parse(run.finishedAt) - Date.parse(run.startedAt)) : (Date.now() - Date.parse(run.startedAt)),
    };
}

function startActionRun(actionName, definition, request, response) {
    const env = request.params.env;
    const startedAt = Date.now();
    const lockKey = `${env}:deploy`;

    if (!definition) {
        response.status(404).json({
            success: false,
            message: `Action is not allowed: ${request.params.action}`,
        });
        return;
    }

    if (definition.method !== 'POST') {
        response.status(405).json({
            success: false,
            message: 'Only POST actions can be started as command runs.',
        });
        return;
    }

    if (definition.locked && runningEnvActions.has(lockKey)) {
        response.status(409).json({
            success: false,
            message: `Action already running for ${env}`,
        });
        return;
    }

    if (definition.locked) {
        runningEnvActions.set(lockKey, actionName);
    }

    const runId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    const run = {
        id: runId,
        environment: env,
        action: actionName,
        startedAt: new Date(startedAt).toISOString(),
        finishedAt: null,
        running: true,
        success: false,
        exitCode: null,
        stdout: '',
        stderr: '',
        timedOut: false,
    };

    commandRuns.set(runId, run);

    const spec = commandSpec(definition, env);
    appendLog({
        event: 'dispatch',
        method: request.method,
        path: request.path,
        env,
        action: actionName,
        run_id: runId,
        requester_ip: requesterIp(request),
    });

    const child = spawn(spec.command, spec.args, {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    const timer = setTimeout(() => {
        run.timedOut = true;
        child.kill('SIGTERM');
    }, definition.timeoutMs);

    child.stdout.on('data', (chunk) => appendRunOutput(run, 'stdout', chunk));
    child.stderr.on('data', (chunk) => appendRunOutput(run, 'stderr', chunk));
    child.on('error', (error) => appendRunOutput(run, 'stderr', error.message));
    child.on('close', (code) => {
        clearTimeout(timer);

        if (definition.locked) {
            runningEnvActions.delete(lockKey);
        }

        run.running = false;
        run.finishedAt = new Date().toISOString();
        run.exitCode = typeof code === 'number' ? code : 1;
        run.success = run.exitCode === 0 && !run.timedOut;

        if (run.timedOut) {
            appendRunOutput(run, 'stderr', '\nCommand timed out.');
        }

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: actionName,
            run_id: runId,
            requester_ip: requesterIp(request),
            success: run.success,
            exit_code: run.exitCode,
            duration_ms: Date.now() - startedAt,
        });

        setTimeout(() => commandRuns.delete(runId), runTtlMs);
    });

    response.status(202).json(commandRunPayload(run));
}

function startSiteActionRun(actionName, definition, request, response) {
    const { site, env } = request.params;
    const startedAt = Date.now();
    const lockKey = `${site}/${env}:deploy`;

    if (!definition) {
        response.status(404).json({
            success: false,
            message: `Action is not allowed: ${request.params.action}`,
        });
        return;
    }

    if (definition.method !== 'POST') {
        response.status(405).json({
            success: false,
            message: 'Only POST actions can be started as command runs.',
        });
        return;
    }

    if (definition.locked && runningEnvActions.has(lockKey)) {
        response.status(409).json({
            success: false,
            message: `Action already running for ${site}/${env}`,
        });
        return;
    }

    if (definition.locked) {
        runningEnvActions.set(lockKey, actionName);
    }

    const runId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    const run = {
        id: runId,
        site,
        environment: env,
        action: actionName,
        startedAt: new Date(startedAt).toISOString(),
        finishedAt: null,
        running: true,
        success: false,
        exitCode: null,
        stdout: '',
        stderr: '',
        timedOut: false,
    };

    commandRuns.set(runId, run);

    const spec = commandSpec(definition, site, env);
    appendLog({
        event: 'dispatch',
        method: request.method,
        path: request.path,
        site,
        env,
        action: actionName,
        run_id: runId,
        requester_ip: requesterIp(request),
    });

    const child = spawn(spec.command, spec.args, {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    const timer = setTimeout(() => {
        run.timedOut = true;
        child.kill('SIGTERM');
    }, definition.timeoutMs);

    child.stdout.on('data', (chunk) => appendRunOutput(run, 'stdout', chunk));
    child.stderr.on('data', (chunk) => appendRunOutput(run, 'stderr', chunk));
    child.on('error', (error) => appendRunOutput(run, 'stderr', error.message));
    child.on('close', (code) => {
        clearTimeout(timer);

        if (definition.locked) {
            runningEnvActions.delete(lockKey);
        }

        run.running = false;
        run.finishedAt = new Date().toISOString();
        run.exitCode = typeof code === 'number' ? code : 1;
        run.success = run.exitCode === 0 && !run.timedOut;

        if (run.timedOut) {
            appendRunOutput(run, 'stderr', '\nCommand timed out.');
        }

        appendLog({
            method: request.method,
            path: request.path,
            site,
            env,
            action: actionName,
            run_id: runId,
            requester_ip: requesterIp(request),
            success: run.success,
            exit_code: run.exitCode,
            duration_ms: Date.now() - startedAt,
        });

        setTimeout(() => commandRuns.delete(runId), runTtlMs);
    });

    response.status(202).json(commandRunPayload(run));
}

function startPromoteRun(request, response) {
    const { site, fromEnv, toEnv } = request.params;
    const startedAt = Date.now();
    const lockKey = `${site}/${toEnv}:deploy`;

    if (runningEnvActions.has(lockKey)) {
        response.status(409).json({
            success: false,
            message: `Action already running for ${site}/${toEnv}`,
        });
        return;
    }

    runningEnvActions.set(lockKey, 'promote');

    const runId = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 10)}`;
    const run = {
        id: runId,
        site,
        environment: toEnv,
        fromEnvironment: fromEnv,
        action: 'promote',
        startedAt: new Date(startedAt).toISOString(),
        finishedAt: null,
        running: true,
        success: false,
        exitCode: null,
        stdout: '',
        stderr: '',
        timedOut: false,
    };

    commandRuns.set(runId, run);

    const spec = commandSpec(promoteAction, site, fromEnv, toEnv);
    appendLog({
        event: 'dispatch',
        method: request.method,
        path: request.path,
        site,
        from_env: fromEnv,
        to_env: toEnv,
        action: 'promote',
        run_id: runId,
        requester_ip: requesterIp(request),
    });

    const child = spawn(spec.command, spec.args, {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    const timer = setTimeout(() => {
        run.timedOut = true;
        child.kill('SIGTERM');
    }, promoteAction.timeoutMs);

    child.stdout.on('data', (chunk) => appendRunOutput(run, 'stdout', chunk));
    child.stderr.on('data', (chunk) => appendRunOutput(run, 'stderr', chunk));
    child.on('error', (error) => appendRunOutput(run, 'stderr', error.message));
    child.on('close', (code) => {
        clearTimeout(timer);
        runningEnvActions.delete(lockKey);

        run.running = false;
        run.finishedAt = new Date().toISOString();
        run.exitCode = typeof code === 'number' ? code : 1;
        run.success = run.exitCode === 0 && !run.timedOut;

        if (run.timedOut) {
            appendRunOutput(run, 'stderr', '\nCommand timed out.');
        }

        appendLog({
            method: request.method,
            path: request.path,
            site,
            from_env: fromEnv,
            to_env: toEnv,
            action: 'promote',
            run_id: runId,
            requester_ip: requesterIp(request),
            success: run.success,
            exit_code: run.exitCode,
            duration_ms: Date.now() - startedAt,
        });

        setTimeout(() => commandRuns.delete(runId), runTtlMs);
    });

    response.status(202).json(commandRunPayload(run));
}

function readActionRun(request, response) {
    const run = commandRuns.get(request.params.runId || request.params.jobId);

    if (!run) {
        response.status(404).json({
            success: false,
            status: 'failed',
            message: 'Command run not found.',
        });
        return;
    }

    response.status(run.running || run.success ? 200 : 500).json(commandRunPayload(run));
}

function runAction(actionName, definition, request, response) {
    const env = request.params.env;
    const startedAt = Date.now();
    const lockKey = `${env}:deploy`;

    if (definition.locked && runningEnvActions.has(lockKey)) {
        response.status(409).json({
            success: false,
            message: `Action already running for ${env}`,
        });
        return;
    }

    if (definition.locked) {
        runningEnvActions.set(lockKey, actionName);
    }

    const spec = commandSpec(definition, env);
    const child = spawn(spec.command, spec.args, {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let timedOut = false;

    const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGTERM');
    }, definition.timeoutMs);

    child.stdout.on('data', (chunk) => {
        stdout += chunk.toString();
    });

    child.stderr.on('data', (chunk) => {
        stderr += chunk.toString();
    });

    child.on('error', (error) => {
        stderr += error.message;
    });

    child.on('close', (code) => {
        clearTimeout(timer);

        if (definition.locked) {
            runningEnvActions.delete(lockKey);
        }

        const durationMs = Date.now() - startedAt;
        const success = code === 0 && !timedOut;
        const exitCode = typeof code === 'number' ? code : 1;

        appendLog({
            method: request.method,
            path: request.path,
            env,
            action: actionName,
            requester_ip: requesterIp(request),
            success,
            exit_code: exitCode,
            duration_ms: durationMs,
        });

        response.status(success ? 200 : 500).json({
            success,
            exit_code: exitCode,
            stdout,
            stderr: timedOut ? `${stderr}\nCommand timed out.`.trim() : stderr,
            duration_ms: durationMs,
        });
    });
}

function runSiteAction(actionName, definition, request, response) {
    const { site, env } = request.params;
    const startedAt = Date.now();
    const lockKey = `${site}/${env}:deploy`;

    if (definition.locked && runningEnvActions.has(lockKey)) {
        response.status(409).json({
            success: false,
            message: `Action already running for ${site}/${env}`,
        });
        return;
    }

    if (definition.locked) {
        runningEnvActions.set(lockKey, actionName);
    }

    const spec = commandSpec(definition, site, env);
    const child = spawn(spec.command, spec.args, {
        shell: false,
        stdio: ['ignore', 'pipe', 'pipe'],
    });

    let stdout = '';
    let stderr = '';
    let timedOut = false;

    const timer = setTimeout(() => {
        timedOut = true;
        child.kill('SIGTERM');
    }, definition.timeoutMs);

    child.stdout.on('data', (chunk) => {
        stdout += chunk.toString();
    });

    child.stderr.on('data', (chunk) => {
        stderr += chunk.toString();
    });

    child.on('error', (error) => {
        stderr += error.message;
    });

    child.on('close', (code) => {
        clearTimeout(timer);

        if (definition.locked) {
            runningEnvActions.delete(lockKey);
        }

        const durationMs = Date.now() - startedAt;
        const success = code === 0 && !timedOut;
        const exitCode = typeof code === 'number' ? code : 1;

        appendLog({
            method: request.method,
            path: request.path,
            site,
            env,
            action: actionName,
            requester_ip: requesterIp(request),
            success,
            exit_code: exitCode,
            duration_ms: durationMs,
        });

        const payload = {
            success,
            exit_code: exitCode,
            stdout,
            stderr: timedOut ? `${stderr}\nCommand timed out.`.trim() : stderr,
            duration_ms: durationMs,
        };

        if (actionName === 'deployKey') {
            payload.public_key = success ? stdout.trim().split(/\r?\n/).filter((line) => line.startsWith('ssh-')).pop() || '' : '';
        }

        response.status(success ? 200 : 500).json(payload);
    });
}

/** Public health — must stay before {@link requireApiKey} middleware so probes need no runner key. */
function handleRunnerHealth(request, response) {
    const healthIp = requesterIp(request);
    const correlationId = runnerCorrelationId(request);
    appendLog({
        method: request.method,
        path: request.path,
        action: 'health',
        requester_ip: healthIp,
        runner_correlation_id: correlationId,
        success: true,
        duration_ms: 0,
    });
    if (envTruthy('MANAGED_AGENT_LOG_HEALTH_IP', 'RELEASEPANEL_LOG_HEALTH_IP')) {
        const cidSuffix = correlationId ? ` correlation_id=${correlationId}` : '';
        console.error(`[managed-deploy-agent] /health requester_ip=${healthIp}${cidSuffix}`);
    }

    response.json({
        ...healthContract(),
        success: true,
        exit_code: 0,
        stdout: 'ok',
        stderr: '',
        duration_ms: 0,
    });
}

app.get('/health', handleRunnerHealth);
app.get('/api/health', handleRunnerHealth);

app.use(requireApiKey);

app.get('/sites', (request, response) => {
    response.json({
        success: true,
        sites: listSiteConfigs(),
    });
});

app.get('/sites/:site/environments', (request, response) => {
    const site = request.params.site;

    if (!isSafeSlug(site)) {
        response.status(400).json({
            success: false,
            message: `Invalid site: ${site}`,
        });
        return;
    }

    const match = listSiteConfigs().find((candidate) => candidate.slug === site);

    response.status(match ? 200 : 404).json({
        success: Boolean(match),
        site,
        environments: match?.environments || [],
    });
});

for (const [actionName, definition] of Object.entries(siteActions)) {
    app[definition.method.toLowerCase()](definition.route, validateSiteEnv, (request, response) => {
        runSiteAction(actionName, definition, request, response);
    });
}

app.post('/runs/:site/:env/:action', validateSiteEnv, (request, response) => {
    const { actionName, definition } = siteActionDefinition(request.params.action);

    startSiteActionRun(actionName, definition, request, response);
});

app.post('/promote/:site/:fromEnv/:toEnv', validatePromote, (request, response) => {
    startPromoteRun(request, response);
});

app.get('/ops/:site/:env/status', requireApiKey, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    readOpsStatus(request, response);
});

app.get('/ops/:site/:env/logs/:log', requireApiKey, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    readOpsLog(request, response);
});

app.get('/ops/:site/:env/backups', requireApiKey, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    readOpsBackups(request, response);
});

// Remote Laravel shared/.env for a toolkit site (ReleasePanel: GET/PUT /api/.../laravel-env → /env/{site}/{env}).
// Use validateEnvSitePath (not validateSiteEnv) so slugs are not rejected with 400; missing file is 200 + empty contents in readSharedEnv.
app.get('/env/:site/:env', debugEnvRequestMiddleware, validateEnvSitePath, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    readSharedEnv(request, response);
});

app.put('/env/:site/:env', debugEnvRequestMiddleware, validateEnvSitePath, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    writeSharedEnv(request, response);
});

app.get('/env/:envKey', requireApiKey, readSharedEnv);
app.put('/env/:envKey', requireApiKey, writeSharedEnv);

app.get('/deploy-config/:site/:env', requireApiKey, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    readDeployConfig(request, response);
});

app.put('/deploy-config/:site/:env', requireApiKey, (request, response) => {
    request.params.env = `${request.params.site}/${request.params.env}`;
    writeDeployConfig(request, response);
});

app.get('/deploy-config/:envKey', requireApiKey, readDeployConfig);
app.put('/deploy-config/:envKey', requireApiKey, writeDeployConfig);

function panelDeployKeyDir() {
    const preferred = '/run/releasepanel';
    try {
        fs.mkdirSync(preferred, { mode: 0o700, recursive: true });
        fs.chmodSync(preferred, 0o700);
        return preferred;
    } catch (_) {
        const uid = typeof process.getuid === 'function' ? process.getuid() : '0';
        const fallback = path.join(os.tmpdir(), `rp-agent-keys-${uid}`);
        fs.mkdirSync(fallback, { mode: 0o700, recursive: true });
        return fallback;
    }
}

function runDeploySyncForPoll(site, env, deployKeyB64 = null, deployKnownHostsB64 = null, extraCleanupPaths = null, panelPayload = null) {
    const definition = siteActions.deploy;
    const lockKey = `${site}/${env}:deploy`;

    return new Promise((resolve) => {
        if (definition.locked && runningEnvActions.has(lockKey)) {
            resolve({
                success: false,
                exit_code: 1,
                stdout: '',
                stderr: 'Deploy already running for this environment.',
                duration_ms: 0,
            });
            return;
        }

        if (definition.locked) {
            runningEnvActions.set(lockKey, 'deploy');
        }

        const startedAt = Date.now();
        const spec = commandSpec(definition, site, env);

        const createdPaths = [];
        const trackPath = (p) => {
            if (p && typeof p === 'string') {
                createdPaths.push(p);
                if (extraCleanupPaths && typeof extraCleanupPaths.push === 'function') {
                    extraCleanupPaths.push(p);
                }
            }
        };
        const cleanupKey = () => {
            while (createdPaths.length) {
                const p = createdPaths.pop();
                try {
                    if (p) fs.unlinkSync(p);
                } catch (_) {
                    /* ignore */
                }
            }
        };

        let childEnv = { ...process.env };
        if (panelPayload && typeof panelPayload === 'object') {
            const repo = typeof panelPayload.repository_url === 'string' ? panelPayload.repository_url.trim() : '';
            if (repo !== '') {
                childEnv.RELEASEPANEL_REPO = repo;
                childEnv.REPO_URL = repo;
            }
            const branch = typeof panelPayload.branch === 'string' ? panelPayload.branch.trim() : '';
            if (branch !== '') {
                childEnv.RELEASEPANEL_BRANCH = branch;
                childEnv.BRANCH = branch;
            }
            const domain = typeof panelPayload.domain === 'string' ? panelPayload.domain.trim() : '';
            if (domain !== '') {
                childEnv.RELEASEPANEL_SERVER_NAME = domain;
                childEnv.DOMAIN = domain;
            }
        }
        try {
            if (deployKeyB64 && typeof deployKeyB64 === 'string' && deployKeyB64.trim() !== '') {
                const keyDir = panelDeployKeyDir();
                const keyPath = path.join(keyDir, `rp-poll-key-${process.pid}-${Date.now()}.key`);
                fs.writeFileSync(keyPath, Buffer.from(deployKeyB64.trim(), 'base64'), { mode: 0o600 });
                trackPath(keyPath);
                childEnv = { ...childEnv, RELEASEPANEL_PANEL_DEPLOY_KEY_FILE: keyPath };
            }
            const kh = deployKnownHostsB64 && typeof deployKnownHostsB64 === 'string' ? deployKnownHostsB64.trim() : '';
            if (kh !== '') {
                const keyDir = panelDeployKeyDir();
                const knownPath = path.join(keyDir, `rp-poll-known-${process.pid}-${Date.now()}`);
                fs.writeFileSync(knownPath, Buffer.from(kh, 'base64'), { mode: 0o600 });
                trackPath(knownPath);
                childEnv = { ...childEnv, RELEASEPANEL_PANEL_KNOWN_HOSTS_FILE: knownPath };
            } else if (deployKeyB64 && typeof deployKeyB64 === 'string' && deployKeyB64.trim() !== '') {
                childEnv = { ...childEnv, RELEASEPANEL_PANEL_ACCEPT_NEW_GIT: '1' };
            }
        } catch (err) {
            cleanupKey();
            if (definition.locked) {
                runningEnvActions.delete(lockKey);
            }
            resolve({
                success: false,
                exit_code: 1,
                stdout: '',
                stderr: err.message || String(err),
                duration_ms: Date.now() - startedAt,
            });
            return;
        }

        const child = spawn(spec.command, spec.args, {
            shell: false,
            stdio: ['ignore', 'pipe', 'pipe'],
            env: childEnv,
        });

        let stdout = '';
        let stderr = '';
        let timedOut = false;

        const timer = setTimeout(() => {
            timedOut = true;
            child.kill('SIGTERM');
        }, definition.timeoutMs);

        child.stdout.on('data', (chunk) => {
            stdout += chunk.toString();
        });

        child.stderr.on('data', (chunk) => {
            stderr += chunk.toString();
        });

        child.on('error', (error) => {
            stderr += error.message;
            cleanupKey();
        });

        child.on('close', (code) => {
            clearTimeout(timer);
            cleanupKey();

            if (definition.locked) {
                runningEnvActions.delete(lockKey);
            }

            const durationMs = Date.now() - startedAt;
            const success = code === 0 && !timedOut;
            const exitCode = typeof code === 'number' ? code : 1;

            appendLog({
                method: 'POST',
                path: '/poll/deploy',
                site,
                env,
                action: 'deploy',
                requester_ip: 'poll',
                success,
                exit_code: exitCode,
                duration_ms: durationMs,
            });

            resolve({
                success,
                exit_code: exitCode,
                stdout,
                stderr: timedOut ? `${stderr}\nCommand timed out.`.trim() : stderr,
                duration_ms: durationMs,
            });
        });
    });
}

async function reportAgentJobResult(jobId, status, result, errorMessage) {
    const payload = {
        job_id: jobId,
        status,
        result: result || {},
    };
    if (errorMessage) {
        payload.error = String(errorMessage).slice(0, 5000);
    }
    try {
        const res = await panelFetchJson('/api/agent/job-result', { method: 'POST', bodyObj: payload });
        appendLog({
            event: 'agent_job_result',
            job_id: jobId,
            status,
            http_ok: res.ok,
            http_status: res.status,
            ...(!res.ok && (res.status === 401 || res.status === 403)
                ? {
                      auth_code: res.json?.code ?? null,
                      message: res.json?.message ?? null,
                      hint: res.json?.hint ?? null,
                  }
                : {}),
        });
    } catch (err) {
        appendLog({
            event: 'agent_job_result_error',
            job_id: jobId,
            status,
            message: err.message,
        });
    }
}

/**
 * Removes RELEASEPANEL_KNOWN_HOSTS_AUTO_PIN_B64 lines from deploy text for cleaner panel logs.
 * Returns the last captured payload (host keys, base64) for structured agent results.
 *
 * @param {string} text
 * @returns {{ cleaned: string, autoPinB64: string | null }}
 */
function extractAutoPinB64FromDeployOutput(text) {
    if (text == null || typeof text !== 'string') {
        return { cleaned: '', autoPinB64: null };
    }
    const reLine = /^RELEASEPANEL_KNOWN_HOSTS_AUTO_PIN_B64=(.+)$/gm;
    let autoPinB64 = null;
    let m;
    while ((m = reLine.exec(text)) !== null) {
        const v = m[1].trim();
        if (v !== '') {
            autoPinB64 = v;
        }
    }
    const cleaned = text
        .replace(/^RELEASEPANEL_KNOWN_HOSTS_AUTO_PIN_B64=.*$/gm, '')
        .replace(/\n{3,}/g, '\n\n')
        .trim();
    return { cleaned, autoPinB64 };
}

async function executePollDeployJob(job) {
    const payload = job.payload || {};
    const site = payload.site;
    const env = payload.env;

    if (!isSafeSlug(site) || !isSafeSlug(env)) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'invalid_payload' }, 'Invalid site/env in job payload');
        return;
    }

    const cfgPath = siteConfigPath(site, env);
    if (siteToolkitEnvWeak(cfgPath)) {
        console.error(`[managed-deploy-agent] No usable toolkit site env at ${cfgPath} (missing or empty) — running deploy with process/panel-injected env.`);
    }

    await reportAgentJobResult(job.id, 'running', {});

    const cleanupPaths = [];
    try {
        const dk = typeof payload.deploy_key_b64 === 'string' ? payload.deploy_key_b64 : '';
        const kh = typeof payload.deploy_known_hosts_b64 === 'string' ? payload.deploy_known_hosts_b64 : '';
        const outcome = await runDeploySyncForPoll(
            site,
            env,
            dk.trim() !== '' ? dk : null,
            kh.trim() !== '' ? kh : null,
            cleanupPaths,
            payload,
        );
        const rawMerged = `${outcome.stdout || ''}\n${outcome.stderr || ''}`;
        const { cleaned, autoPinB64 } = extractAutoPinB64FromDeployOutput(rawMerged);
        const mergedOut = truncateForAgentPanel(cleaned, maxAgentPanelOutputChars);
        /** @type {Record<string, unknown>} */
        const resultPayload = {
            output: mergedOut,
            exit_code: outcome.exit_code,
            deploy: { exit_code: outcome.exit_code, duration_ms: outcome.duration_ms },
        };
        const minAutoPinB64 = 16;
        const maxAutoPinB64 = 65536;
        if (autoPinB64 && autoPinB64.length >= minAutoPinB64 && autoPinB64.length <= maxAutoPinB64) {
            resultPayload.known_hosts_auto_pin_b64 = autoPinB64;
        }
        if (outcome.success) {
            await reportAgentJobResult(job.id, 'succeeded', resultPayload);
        } else {
            await reportAgentJobResult(job.id, 'failed', resultPayload, outcome.stderr || 'deploy failed');
        }
    } catch (err) {
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
    } finally {
        for (const p of cleanupPaths) {
            try {
                if (p) fs.unlinkSync(p);
            } catch (_) {
                /* ignore */
            }
        }
    }
}

async function executePollSiteCreateJob(job) {
    const payload = job.payload || {};
    const command = typeof payload.command === 'string' ? payload.command : '';
    if (!command.trim()) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'missing_command' }, 'Missing site-create script in job payload');
        return;
    }

    await reportAgentJobResult(job.id, 'running', {});

    const tmp = `/tmp/rp-site-create-${job.id}-${process.pid}.sh`;

    try {
        fs.writeFileSync(tmp, command, { mode: 0o600 });
        const outcome = await new Promise((resolve) => {
            let stdout = '';
            let stderr = '';
            const child = spawn('sudo', ['-n', 'bash', tmp], {
                shell: false,
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            const timer = setTimeout(() => {
                child.kill('SIGTERM');
            }, provisionTimeoutMs);
            child.stdout.on('data', (chunk) => {
                stdout += chunk.toString();
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
            });
            child.on('error', (error) => {
                stderr += error.message;
            });
            child.on('close', (code) => {
                clearTimeout(timer);
                resolve({
                    success: code === 0,
                    exit_code: typeof code === 'number' ? code : 1,
                    stdout,
                    stderr,
                });
            });
        });

        const mergedOut = truncateForAgentPanel(`${outcome.stdout || ''}\n${outcome.stderr || ''}`, maxAgentPanelOutputChars);
        if (outcome.success) {
            await reportAgentJobResult(job.id, 'succeeded', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            });
        } else {
            let errMsg = (outcome.stderr || outcome.stdout || 'site create failed').trim();
            const sudoHint = explainProvisionSudoFailure(outcome.stdout, outcome.stderr);
            if (sudoHint) {
                errMsg = errMsg ? `${errMsg}.${sudoHint}` : `Site create failed.${sudoHint}`;
            }
            await reportAgentJobResult(job.id, 'failed', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            }, errMsg);
        }
    } catch (err) {
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
    } finally {
        try {
            fs.unlinkSync(tmp);
        } catch {
            // ignore
        }
    }
}

async function executePollProvisionJob(job) {
    const payload = job.payload || {};
    const script = typeof payload.script === 'string' ? payload.script : '';
    if (!script.trim()) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'missing_script' }, 'Missing provision script in job payload');
        return;
    }

    await reportAgentJobResult(job.id, 'running', {});

    const tmp = `/tmp/rp-provision-${job.id}-${process.pid}.sh`;

    try {
        fs.writeFileSync(tmp, script, { mode: 0o600 });
        const outcome = await new Promise((resolve) => {
            let stdout = '';
            let stderr = '';
            const child = spawn('sudo', ['-n', 'bash', tmp], {
                shell: false,
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            const timer = setTimeout(() => {
                child.kill('SIGTERM');
            }, provisionTimeoutMs);
            child.stdout.on('data', (chunk) => {
                stdout += chunk.toString();
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
            });
            child.on('error', (error) => {
                stderr += error.message;
            });
            child.on('close', (code) => {
                clearTimeout(timer);
                resolve({
                    success: code === 0,
                    exit_code: typeof code === 'number' ? code : 1,
                    stdout,
                    stderr,
                });
            });
        });

        const mergedOut = truncateForAgentPanel(`${outcome.stdout || ''}\n${outcome.stderr || ''}`, maxAgentPanelOutputChars);
        if (outcome.success) {
            await reportAgentJobResult(job.id, 'succeeded', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            });
        } else {
            let errMsg = (outcome.stderr || outcome.stdout || 'provision failed').trim();
            const sudoHint = explainProvisionSudoFailure(outcome.stdout, outcome.stderr);
            if (sudoHint) {
                errMsg = errMsg ? `${errMsg}.${sudoHint}` : `Provision failed.${sudoHint}`;
            }
            await reportAgentJobResult(job.id, 'failed', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            }, errMsg);
        }
    } catch (err) {
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
    } finally {
        try {
            fs.unlinkSync(tmp);
        } catch {
            // ignore
        }
    }
}

async function executePollSslEnableJob(job) {
    const payload = job.payload || {};
    const command = typeof payload.command === 'string' ? payload.command : '';
    if (!command.trim()) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'missing_command' }, 'Missing ssl-enable script in job payload');
        return;
    }

    await reportAgentJobResult(job.id, 'running', {});

    const tmp = `/tmp/rp-ssl-enable-${job.id}-${process.pid}.sh`;

    try {
        fs.writeFileSync(tmp, command, { mode: 0o600 });
        const outcome = await new Promise((resolve) => {
            let stdout = '';
            let stderr = '';
            const child = spawn('sudo', ['-n', 'bash', tmp], {
                shell: false,
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            const timer = setTimeout(() => {
                child.kill('SIGTERM');
            }, provisionTimeoutMs);
            child.stdout.on('data', (chunk) => {
                stdout += chunk.toString();
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
            });
            child.on('error', (error) => {
                stderr += error.message;
            });
            child.on('close', (code) => {
                clearTimeout(timer);
                resolve({
                    success: code === 0,
                    exit_code: typeof code === 'number' ? code : 1,
                    stdout,
                    stderr,
                });
            });
        });

        const mergedOut = truncateForAgentPanel(`${outcome.stdout || ''}\n${outcome.stderr || ''}`, maxAgentPanelOutputChars);
        if (outcome.success) {
            await reportAgentJobResult(job.id, 'succeeded', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            });
        } else {
            let errMsg = (outcome.stderr || outcome.stdout || 'ssl enable failed').trim();
            const sudoHint = explainProvisionSudoFailure(outcome.stdout, outcome.stderr);
            if (sudoHint) {
                errMsg = errMsg ? `${errMsg}.${sudoHint}` : `SSL enable failed.${sudoHint}`;
            }
            await reportAgentJobResult(job.id, 'failed', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            }, errMsg);
        }
    } catch (err) {
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
    } finally {
        try {
            fs.unlinkSync(tmp);
        } catch {
            // ignore
        }
    }
}

async function executePollPromoteJob(job) {
    const payload = job.payload || {};
    const site = payload.site;
    const fromEnv = payload.from_env;
    const toEnv = payload.to_env;

    if (!isSafeSlug(site) || !isSafeSlug(fromEnv) || !isSafeSlug(toEnv) || fromEnv === toEnv) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'invalid_payload' }, 'Invalid promote payload');
        return;
    }

    const fromPath = siteConfigPath(site, fromEnv);
    const toPath = siteConfigPath(site, toEnv);
    if (siteToolkitEnvWeak(fromPath) || siteToolkitEnvWeak(toPath)) {
        console.error(`[managed-deploy-agent] Missing or empty toolkit env for promote ${site} (${fromEnv}→${toEnv}); continuing.`);
    }

    const lockKey = `${site}/${toEnv}:deploy`;
    if (runningEnvActions.has(lockKey)) {
        await reportAgentJobResult(job.id, 'failed', { reason: 'locked' }, `Action already running for ${site}/${toEnv}`);
        return;
    }

    runningEnvActions.set(lockKey, 'promote');
    await reportAgentJobResult(job.id, 'running', {});

    let spec;
    try {
        spec = commandSpec(promoteAction, site, fromEnv, toEnv);
    } catch (err) {
        runningEnvActions.delete(lockKey);
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
        return;
    }

    const startedAt = Date.now();
    try {
        const outcome = await new Promise((resolve) => {
            let stdout = '';
            let stderr = '';
            const child = spawn(spec.command, spec.args, {
                shell: false,
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            const timer = setTimeout(() => {
                child.kill('SIGTERM');
            }, promoteAction.timeoutMs);
            child.stdout.on('data', (chunk) => {
                stdout += chunk.toString();
            });
            child.stderr.on('data', (chunk) => {
                stderr += chunk.toString();
            });
            child.on('error', (error) => {
                stderr += error.message;
            });
            child.on('close', (code) => {
                clearTimeout(timer);
                resolve({
                    success: code === 0,
                    exit_code: typeof code === 'number' ? code : 1,
                    stdout,
                    stderr,
                });
            });
        });

        const mergedOut = truncateForAgentPanel(`${outcome.stdout || ''}\n${outcome.stderr || ''}`, maxAgentPanelOutputChars);
        if (outcome.success) {
            await reportAgentJobResult(job.id, 'succeeded', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            });
        } else {
            await reportAgentJobResult(job.id, 'failed', {
                output: mergedOut,
                exit_code: outcome.exit_code,
            }, (outcome.stderr || outcome.stdout || 'promote failed').trim());
        }
    } catch (err) {
        await reportAgentJobResult(job.id, 'failed', { exit_code: 1 }, err.message || String(err));
    } finally {
        runningEnvActions.delete(lockKey);
        appendLog({
            event: 'agent_poll_promote',
            site,
            from_env: fromEnv,
            to_env: toEnv,
            duration_ms: Date.now() - startedAt,
            job_id: job.id,
        });
    }
}

let pollCycleBusy = false;

async function runAgentPollCycle() {
    if (!pollEnabled || !panelUrl || !apiKey) {
        return;
    }
    if (pollCycleBusy) {
        return;
    }
    pollCycleBusy = true;
    try {
        const res = await panelFetchJson('/api/agent/poll', {
            method: 'POST',
            bodyObj: {
                agent_version: resolvedRunnerVersionLabel(),
                capabilities: ['deploy', 'provision', 'site_create', 'ssl_enable', 'promote'],
            },
        });
        appendLog({
            event: 'agent_poll',
            http_ok: res.ok,
            http_status: res.status,
        });
        if (!res.ok || !res.json || !res.json.job) {
            if (!res.ok && (res.status === 401 || res.status === 403)) {
                appendLog({
                    event: 'agent_poll_auth_rejected',
                    http_status: res.status,
                    code: res.json?.code ?? null,
                    message: res.json?.message ?? null,
                    hint: res.json?.hint ?? null,
                });
                maybePanelOnboardingRejectedConsoleHint('/api/agent/poll', res);
            }
            return;
        }
        const job = res.json.job;
        if (job.type === 'deploy') {
            await executePollDeployJob(job);
        } else if (job.type === 'provision') {
            await executePollProvisionJob(job);
        } else if (job.type === 'site_create') {
            await executePollSiteCreateJob(job);
        } else if (job.type === 'ssl_enable') {
            await executePollSslEnableJob(job);
        } else if (job.type === 'promote') {
            await executePollPromoteJob(job);
        }
    } catch (error) {
        appendLog({
            event: 'agent_poll_error',
            message: error.message,
        });
    } finally {
        pollCycleBusy = false;
    }
}

registerIfNeeded();

const server = app.listen(port, host, () => {
    appendLog({
        action: 'start',
        success: true,
        duration_ms: 0,
        message: `Managed deploy agent listening on ${host}:${port}`,
    });

    sendHeartbeat();
    setInterval(sendHeartbeat, heartbeatIntervalMs);

    if (pollEnabled && panelUrl) {
        runAgentPollCycle();
        setInterval(runAgentPollCycle, pollIntervalMs);
    }
});

server.on('error', (err) => {
    console.error(`[managed-deploy-agent] listen failed on ${host}:${port}: ${err.code || ''} ${err.message}`.trim());
    appendLog({
        action: 'listen_error',
        success: false,
        message: err.message,
        code: err.code || null,
    });
    process.exit(1);
});
