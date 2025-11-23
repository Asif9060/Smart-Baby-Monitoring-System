# Firebase Permission Fix - SOLVED

## Error

`[firebase_database/permission-denied] permission_denied at /devices: Client doesn't have permission to access the desired data.`

## Root Cause

Your Firebase rules expired on 2025-11-12 (yesterday). Current timestamp: ~1731456000000 (Nov 13, 2025)

## Solution - Update Expiration Date

Go to Firebase Console and update your rules:

1. Open: https://console.firebase.google.com/project/babymonitor-9ea16/database/babymonitor-9ea16-default-rtdb/rules

2. Replace with (expires in 30 days):

```json
{
   "rules": {
      ".read": "now < 1734134400000",
      ".write": "now < 1734134400000"
   }
}
```

**Or for permanent access (development only):**

```json
{
   "rules": {
      ".read": true,
      ".write": true
   }
}
```

3. Click "Publish"

## The App Will Work Immediately After Rules Update

-  Firebase sensor data: ✅ Will load once rules are updated
-  Camera feed: ✅ Already works (uses direct HTTP to ESP32, not Firebase)
