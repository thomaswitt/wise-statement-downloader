WISE statement downloader for downloading WISE account statements as PDF
via API.

Before starting, you need to create a [personal token](https://docs.wise.com/api-docs/features/strong-customer-authentication-2fa/personal-token-sca) and [a RSA certificate](https://docs.wise.com/api-docs/features/strong-customer-authentication-2fa/personal-token-sca), as statement downloading is a 2 factor auth operation:

```
openssl genrsa -out certs/wise-private.pem 2048
openssl rsa -pubout -in certs/wise-private.pem -out certs/wise-public.pem
```

For details, see my blog post:

https://thomas-witt.com/download-wise-com-account-balance-statements-as-pdf-via-api-03ad78574103
