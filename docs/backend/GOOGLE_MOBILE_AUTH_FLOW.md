# Google Mobile Auth Flow

## Overview

The `/oauth/google/mobile` endpoint allows mobile clients (Expo/React Native) to authenticate using a Google ID token. Unlike the web OAuth flow which uses redirects and authorization codes, the mobile flow receives a pre-obtained ID token directly from the client.

## Flow

```
Mobile App                    Backend                         Google
    |                            |                               |
    |--- Google Sign-In -------->|                               |
    |                            |                               |
    |<-- Google ID Token --------|                               |
    |                            |                               |
    |-- POST /google/mobile ---->|                               |
    |   { id_token: "..." }      |-- verify JWT signature ------>|
    |                            |<-- public keys (cached) ------|
    |                            |                               |
    |                            |-- check aud in allowed list   |
    |                            |-- find/create user in DB      |
    |                            |-- generate access+refresh     |
    |                            |                               |
    |<-- { tokens, user } -------|                               |
```

## Steps

### 1. Mobile App Signs In with Google

The mobile app uses the `GOOGLE_IOS_CLIENT_ID` (or Android equivalent) to initiate Google Sign-In and receives a Google **ID token** (a JWT).

### 2. Mobile App Sends the ID Token to the Backend

```
POST /oauth/google/mobile
Content-Type: application/json

{
  "id_token": "<google-jwt>"
}
```

### 3. Backend Verifies the Token

- `google.oauth2.id_token.verify_oauth2_token()` checks the JWT signature, expiry, and issuer against Google's public keys.
- The `aud` (audience) claim is validated against `CONFIG.GOOGLE_ALLOWED_AUDIENCES`, which should include both the web and iOS client IDs.

### 4. Extract User Info

User information is extracted from the verified token claims:

- `sub` (Google user ID)
- `email`
- `name`
- `picture` (avatar URL)

### 5. Create or Update User

The backend finds an existing user by email or creates a new one:

- Sets the OAuth provider and provider ID
- Updates profile picture if available
- Marks email as verified (Google always verifies emails)

### 6. Return App Tokens

The backend generates its own JWT access/refresh token pair and returns them along with the user profile.

### Response

```json
{
  "message": "User authenticated successfully via Google OAuth",
  "access_token": "<jwt-access-token>",
  "refresh_token": "<jwt-refresh-token>",
  "user": {
    "id": 1,
    "email": "user@gmail.com",
    "username": "user",
    "oauth_provider": "google",
    "profile_picture": "https://..."
  }
}
```

## Key Files

- `ressy_backend/routes/oauth.py` - Route handler (`google_mobile`)
- `ressy_backend/services/oauth_service.py` - Token verification (`verify_google_id_token`) and user creation (`create_or_update_user_from_oauth`)

## Configuration

The following environment variables are required:

- `GOOGLE_WEB_CLIENT_ID` - Google OAuth web client ID
- `GOOGLE_IOS_CLIENT_ID` - Google OAuth iOS client ID
- `GOOGLE_WEB_CLIENT_SECRET` - Google OAuth web client secret
- `GOOGLE_ALLOWED_AUDIENCES` - List of allowed audience values for ID token validation (should include both web and iOS client IDs)
