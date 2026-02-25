# Security Policy

## Reporting Vulnerabilities

If you discover a security vulnerability, please report it responsibly:

📧 **Email**: rafael.franca@live.com  
⏱️ **Response**: Within 48 hours

**Do NOT open a public issue for security vulnerabilities.**

## Security Practices

This project follows security best practices:

- ✅ No credentials, tokens, or secrets in the codebase
- ✅ All authentication uses Azure CLI context or Managed Identity
- ✅ App Registration secrets are generated dynamically, never stored in code
- ✅ Managed Identity follows Zero Trust principles
- ✅ Azure Policy uses `DeployIfNotExists` — compliant resources are never modified
- ✅ Minimum required RBAC permissions (Reader, not Contributor)
- ✅ Graph API permissions limited to `Group.ReadWrite.All` and `Device.Read.All`

## Credential Management

The script generates credentials at runtime (Stage 14). These are saved to a local temp file with a warning to store securely. The credentials are **never** committed to source control.
