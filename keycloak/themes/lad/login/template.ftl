<#-- Каркас усіх сторінок входу «Лад». Той самий інтерфейс макросу, що в base/template.ftl
     (секції header, show-username, form, socialProviders, info), тож сторінки base працюють без змін. -->
<#macro registrationLayout bodyClass="" displayInfo=false displayMessage=true displayRequiredFields=false>
<!DOCTYPE html>
<html lang="${lang}">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>${msg("ladName")}</title>
    <link rel="icon" type="image/svg+xml" href="${url.resourcesPath}/img/favicon.svg">
    <#if properties.styles?has_content>
        <#list properties.styles?split(' ') as style>
            <link href="${url.resourcesPath}/${style}" rel="stylesheet">
        </#list>
    </#if>
    <script type="module">
        <#outputformat "JavaScript">
        import { startSessionPolling } from ${(url.resourcesPath + "/js/authChecker.js")?c};
        startSessionPolling(${url.ssoLoginInOtherTabsUrl?c});
        </#outputformat>
    </script>
    <#if authenticationSession??>
        <script type="module">
            <#outputformat "JavaScript">
            import { checkAuthSession } from ${(url.resourcesPath + "/js/authChecker.js")?c};
            checkAuthSession(${authenticationSession.authSessionIdHash?c});
            </#outputformat>
        </script>
    </#if>
</head>
<body class="lad ${bodyClass}" data-page-id="login-${pageId}">
<main class="lad-page">
    <div class="lad-card">
        <div class="lad-brand">
            <span class="lad-mark" aria-hidden="true">
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v3.5M12 3h4l-1 1.2 1 1.3h-4"/><path d="m3 11 9-5 9 5"/><path d="M5 10v10h14V10"/><path d="M10 20v-4.5a2 2 0 0 1 4 0V20"/><path d="M8 13h.01M16 13h.01"/></svg>
            </span>
            <span class="lad-brand-text">
                <b>${msg("ladName")}</b>
                <small>${msg("ladTagline")}</small>
            </span>
        </div>

        <#if bodyClass?contains("lad-login")>
            <p class="lad-lead"><#nested "header"></p>
        <#else>
            <h1 class="lad-title"><#nested "header"></h1>
        </#if>

        <#if auth?has_content && auth.showUsername() && !auth.showResetCredentials()>
            <#nested "show-username">
            <p class="lad-user">
                ${msg("ladUsername")}: <b>${auth.attemptedUsername}</b>
                · <a href="${url.loginRestartFlowUrl}">${msg("ladRestart")}</a>
            </p>
        </#if>

        <#if displayMessage && message?has_content && (message.type != 'warning' || !isAppInitiatedAction??)>
            <div class="lad-alert lad-alert-${message.type}" role="alert">${kcSanitize(message.summary)?no_esc}</div>
        </#if>

        <#nested "form">

        <#nested "socialProviders">

        <#if displayInfo>
            <div class="lad-info"><#nested "info"></div>
        </#if>
    </div>

    <#if realm.internationalizationEnabled && locale.supported?size gt 1>
        <nav class="lad-locales" aria-label="${msg("languages")}">
            <#list locale.supported as l>
                <#assign name = l.languageTag?starts_with("uk")?then("Українська", "English")>
                <#if l.languageTag == locale.currentLanguageTag>
                    <span aria-current="true" lang="${l.languageTag}">${name}</span>
                <#else>
                    <a href="${l.url}" lang="${l.languageTag}">${name}</a>
                </#if>
            </#list>
        </nav>
    </#if>
</main>
</body>
</html>
</#macro>
