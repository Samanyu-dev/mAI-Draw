# Supabase Setup Guide

This guide provides instructions for contributors to configure and run Supabase authentication and synchronization locally or in their own remote Supabase instance for **mAI-Draw**.

## Environment Keys

The application requires two environment variables to connect to Supabase:
- `SUPABASE_URL`: The URL of your Supabase project (e.g., `https://<your-project-id>.supabase.co` or `http://127.0.0.1:54321` for local).
- `SUPABASE_KEY`: Your Supabase anon (public) key.

**How to configure:**
These keys are loaded by the `AppSecrets` utility. You can provide them by:
1. **Xcode Environment Variables:** Edit the active scheme in Xcode (Product > Scheme > Edit Scheme), go to Run > Arguments, and add `SUPABASE_URL` and `SUPABASE_KEY` under "Environment Variables".
2. **Info.plist / Build Config:** Adding them to an `.xcconfig` file that is linked to your `Info.plist`.

## Required Tables and Schema

The application relies on the following relational tables:

### 1. `projects`
Stores the metadata for each canvas document.
- `id` (uuid, primary key)
- `user_id` (uuid, references `auth.users`)
- `title` (text)
- `prompt` (text, nullable)
- `created_at` (timestamptz)
- `updated_at` (timestamptz)
- `connections` (jsonb, nullable)

### 2. `elements`
Stores the individual elements (post its, markdown cards, text, etc.) placed inside a project.
- `id` (uuid or bigint, primary key, auto generated)
- `project_id` (uuid, references `projects.id` with cascade delete)
- `user_id` (uuid, references `auth.users`)
- `type` (text)
- `content` (text, nullable)
- `position_x` (float8)
- `position_y` (float8)
- `width` (float8)
- `height` (float8)
- `metadata` (jsonb, nullable)

## Storage Buckets

The app uses four separate storage buckets to sync binary assets. Ensure these buckets are created and made public (if necessary for your setup) or require auth:
- `drawings`
- `thumbnails`
- `images`
- `audio`

**File Path Structure:**
All files are stored in the following format:
`{user_id}/{project_id}/{filename}`

## Row Level Security (RLS) Expectations

The app is built with user data privacy in mind. **All tables and storage buckets must have Row Level Security (RLS) enabled.**

> [!IMPORTANT]
> The app identifies users via `SupabaseManager.shared.currentUserId`. All API operations are authenticated.

**Table Policies:**
For both `projects` and `elements` tables, you should enforce policies that ensure users can only access their own data:
- **SELECT / INSERT / UPDATE / DELETE:**
  `auth.uid() = user_id`

**Storage Policies:**
Since all file paths start with the `user_id`, you must restrict storage access based on the folder path.
- **SELECT / INSERT / UPDATE / DELETE:**
  Users can only perform operations where the first segment of the storage path matches their user ID. Example condition:
  `(storage.foldername(name))[1] = auth.uid()::text`

## Local Test Setup

To test the application locally without affecting production data:

1. **Install Supabase CLI:**
   Ensure you have Docker installed, then install the [Supabase CLI](https://supabase.com/docs/guides/cli).
2. **Initialize and Start:**
   Run the following commands in a dedicated directory:
   ```bash
   supabase init
   supabase start
   ```
3. **Apply Schema:**
   Create the tables and buckets via the Supabase Studio running locally (typically `http://localhost:54323`) or by adding migration scripts to the `supabase/migrations` folder.
4. **Configure Xcode:**
   Copy the `API URL` and `anon key` printed in the terminal after `supabase start`. Add them as `SUPABASE_URL` and `SUPABASE_KEY` environment variables in your Xcode project scheme.
5. **Run the App:**
   Build and run the app in the simulator. Create a user via the app's login flow (which will be saved in your local Supabase instance) and begin testing sync.
