"""Отправка Magic Link и PIN-кода через SMTP.

Адаптировано из MonPap. Использует aiosmtplib для async-отправки.
Поддерживает Gmail (порт 587 / STARTTLS) и Yandex (порт 465 / implicit TLS).
"""

import logging

import aiosmtplib
from email.mime.text import MIMEText

from app.core.config import get_settings

logger = logging.getLogger(__name__)
settings = get_settings()


async def send_magic_link(email: str, token: str, base_url: str = "", pin_code: str = "") -> bool:
    """Отправляет Magic Link и PIN-код на указанный email.

    Args:
        email: Email получателя
        token: JWT-токен для верификации
        base_url: Базовый URL приложения
        pin_code: 6-значный PIN-код для ввода вручную

    Returns:
        True если письмо отправлено, False при ошибке.
    """
    verify_url = f"{base_url}/api/v1/auth/verify?token={token}"

    pin_section = ""
    if pin_code:
        pin_section = f"""
        <div style="background: #f0f0f0; border-radius: 12px; padding: 20px; margin: 16px 0; text-align: center;">
            <p style="color: #666; font-size: 13px; margin: 0 0 8px 0;">Или введите код в приложении:</p>
            <div style="font-size: 32px; font-weight: 700; letter-spacing: 8px; color: #6C5CE7; font-family: monospace;">
                {pin_code}
            </div>
        </div>
        """

    html = f"""
    <div style="font-family: -apple-system, sans-serif; max-width: 400px; margin: 0 auto; padding: 32px;">
        <h2 style="color: #6C5CE7;">MonPapa</h2>
        <p>Нажмите кнопку для входа в приложение:</p>
        <a href="{verify_url}"
           style="display: inline-block; background: #6C5CE7; color: white;
                  padding: 12px 32px; border-radius: 8px; text-decoration: none;
                  font-weight: 600; margin: 16px 0;">
            Войти в MonPapa
        </a>
        {pin_section}
        <p style="color: #888; font-size: 13px;">
            Ссылка и код действительны 15 минут. Если вы не запрашивали вход — проигнорируйте это письмо.
        </p>
    </div>
    """

    msg = MIMEText(html, "html", "utf-8")
    msg["Subject"] = f"Вход в MonPapa — код {pin_code}" if pin_code else "Вход в MonPapa"
    msg["From"] = settings.SMTP_FROM
    msg["To"] = email

    try:
        # Порт 465 = implicit TLS (use_tls), порт 587 = STARTTLS (start_tls)
        use_tls = settings.SMTP_PORT == 465
        start_tls = settings.SMTP_PORT == 587

        await aiosmtplib.send(
            msg,
            hostname=settings.SMTP_HOST,
            port=settings.SMTP_PORT,
            username=settings.SMTP_USER,
            password=settings.SMTP_PASSWORD,
            use_tls=use_tls,
            start_tls=start_tls,
        )
        logger.info(f"Magic Link отправлен на {email}")
        return True
    except Exception as e:
        logger.error(f"Ошибка отправки Magic Link на {email}: {e}")
        return False
