<#-- Вхід укладача розкладу й системного адміністратора: логін і пароль, як у прототипі «Лад».
     Логін, а не пошта: пошту система не зберігає (мінімізація ПД). Відновлення пароля через
     пошту немає — пароль скидає адмін у консолі Keycloak (рішення специфікації). -->
<#import "template.ftl" as layout>
<@layout.registrationLayout bodyClass="lad-login" displayMessage=!messagesPerField.existsError('username','password'); section>
    <#if section = "header">
        ${msg("ladLead")}
    <#elseif section = "form">
        <#if realm.password>
        <form id="kc-form-login" class="lad-form" onsubmit="login.disabled = true; return true;" action="${url.loginAction}" method="post">
            <#if !usernameHidden??>
                <label class="lad-field">
                    <span>${msg("ladUsername")}</span>
                    <input id="username" name="username" type="text" value="${(login.username!'')}"
                           autofocus autocomplete="username" autocapitalize="none" spellcheck="false" dir="ltr"
                           aria-invalid="<#if messagesPerField.existsError('username','password')>true</#if>">
                </label>
            </#if>
            <label class="lad-field">
                <span>${msg("password")}</span>
                <input id="password" name="password" type="password" autocomplete="current-password" dir="ltr"
                       aria-invalid="<#if messagesPerField.existsError('username','password')>true</#if>">
            </label>
            <#if messagesPerField.existsError('username','password')>
                <p class="lad-error" id="input-error" aria-live="polite">${kcSanitize(messagesPerField.getFirstError('username','password'))?no_esc}</p>
            </#if>
            <input type="hidden" id="id-hidden-input" name="credentialId" <#if auth.selectedCredential?has_content>value="${auth.selectedCredential}"</#if>>
            <button class="lad-button" name="login" id="kc-login" type="submit">${msg("ladDoLogIn")}</button>
        </form>
        </#if>
        <div class="lad-hints">
            <p>${msg("ladForgot")}</p>
            <p>${msg("ladQrHint")}</p>
        </div>
    </#if>
</@layout.registrationLayout>
