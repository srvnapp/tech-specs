-- ============================================================
-- SRVN - AI-Ready PostgreSQL Schema
-- ============================================================
-- Extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- USERS
-- ============================================================
CREATE TABLE users (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
username TEXT UNIQUE NOT NULL,
email TEXT UNIQUE NOT NULL,
full_name TEXT,
avatar_url TEXT,
city TEXT DEFAULT 'Toronto',
location GEOGRAPHY(Point, 4326), -- real-time location
created_at TIMESTAMPTZ DEFAULT NOW(),
updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Onboarding signals (seed data for AI before behavior exists)
    favourite_cuisines  TEXT[],
    dietary_restrictions TEXT[],
    dining_frequency    TEXT,                             -- 'daily', 'weekly', 'monthly'
    typical_group_size  INT,
    price_preference    TEXT,                             -- 'budget', 'mid', 'upscale', 'luxury'
    typical_occasions   TEXT[],                           -- 'date_night', 'group', 'solo', 'business'

    -- AI layer
    taste_embedding     vector(1536),                     -- OpenAI embedding of taste profile
    taste_profile_json  JSONB,                            -- human-readable taste summary
    taste_confidence    FLOAT DEFAULT 0.0,                -- 0 to 1, how much signal we have
    last_embedding_at   TIMESTAMPTZ                       -- when embedding was last updated

);

-- ============================================================
-- RESTAURANTS
-- ============================================================
CREATE TABLE restaurants (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
name TEXT NOT NULL,
slug TEXT UNIQUE NOT NULL,
address TEXT,
city TEXT DEFAULT 'Toronto',
location GEOGRAPHY(Point, 4326),
neighbourhood TEXT, -- 'King West', 'Kensington', 'Ossington'
phone TEXT,
website TEXT,
opentable_id TEXT, -- for direct booking integration
google_place_id TEXT,
price_range INT CHECK (price_range BETWEEN 1 AND 4),
cuisines TEXT[],
dietary_options TEXT[], -- 'vegan', 'gluten-free', 'halal', etc.
atmosphere_tags TEXT[], -- 'cozy', 'loud', 'intimate', 'trendy'
best_for TEXT[], -- 'date_night', 'groups', 'business', 'solo'
hours JSONB, -- structured hours per day
is_active BOOLEAN DEFAULT TRUE,
created_at TIMESTAMPTZ DEFAULT NOW(),
updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- AI layer
    embedding           vector(1536),                     -- semantic embedding of restaurant profile
    description_rich    TEXT,                             -- rich text fed into embedding
    ai_summary          TEXT                              -- AI-generated summary for concierge use

);

-- ============================================================
-- DISHES
-- ============================================================
-- Dish-level granularity is critical for the taste graph
CREATE TABLE dishes (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
name TEXT NOT NULL,
description TEXT,
price NUMERIC(10,2),
category TEXT, -- 'starter', 'main', 'dessert', 'drink'
dietary_tags TEXT[],
is_signature BOOLEAN DEFAULT FALSE, -- chef's special / must-order
is_available BOOLEAN DEFAULT TRUE,
created_at TIMESTAMPTZ DEFAULT NOW(),

    -- AI layer
    embedding           vector(1536)                      -- semantic embedding of dish profile

);

-- ============================================================
-- FOLLOWS (Social Graph)
-- ============================================================
CREATE TABLE follows (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
follower_id UUID REFERENCES users(id) ON DELETE CASCADE,
following_id UUID REFERENCES users(id) ON DELETE CASCADE,
created_at TIMESTAMPTZ DEFAULT NOW(),
UNIQUE (follower_id, following_id)
);

-- ============================================================
-- REVIEWS
-- ============================================================
CREATE TABLE reviews (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
rating INT CHECK (rating BETWEEN 1 AND 5),
body TEXT,
visited_at DATE, -- when they actually went
occasion TEXT, -- 'date_night', 'birthday', 'casual', etc.
group_size INT,
would_return BOOLEAN,
created_at TIMESTAMPTZ DEFAULT NOW(),
updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- Context (critical for AI signal quality)
    source              TEXT,                             -- 'post_event', 'organic', 'prompted'
    event_id            UUID,                             -- if review came from an event

    -- AI layer
    embedding           vector(1536),                     -- semantic meaning of review text
    sentiment_score     FLOAT,                            -- -1 to 1
    sentiment_aspects   JSONB                             -- {'food': 0.9, 'service': 0.4, 'ambiance': 0.8}

);

-- ============================================================
-- REVIEW INTERACTIONS
-- ============================================================
CREATE TABLE review_likes (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
review_id UUID REFERENCES reviews(id) ON DELETE CASCADE,
created_at TIMESTAMPTZ DEFAULT NOW(),

    -- Context columns (critical for signal quality)
    source              TEXT,                             -- 'feed', 'restaurant_page', 'profile', 'search'
    session_id          UUID,
    time_of_day         TEXT,                             -- 'morning', 'lunch', 'evening', 'late_night'
    day_of_week         INT,                              -- 0=Sunday, 6=Saturday
    UNIQUE (user_id, review_id)

);

CREATE TABLE review_saves (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
review_id UUID REFERENCES reviews(id) ON DELETE CASCADE,
created_at TIMESTAMPTZ DEFAULT NOW(),
source TEXT,
session_id UUID,
time_of_day TEXT,
day_of_week INT,
UNIQUE (user_id, review_id)
);

-- ============================================================
-- DISH MENTIONS IN REVIEWS
-- ============================================================
CREATE TABLE review_dishes (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
review_id UUID REFERENCES reviews(id) ON DELETE CASCADE,
dish_id UUID REFERENCES dishes(id) ON DELETE SET NULL,
dish_name_raw TEXT, -- what user typed, even if no dish match
rating INT CHECK (rating BETWEEN 1 AND 5),
notes TEXT
);

-- ============================================================
-- RESTAURANT SAVES
-- ============================================================
CREATE TABLE restaurant_saves (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
created_at TIMESTAMPTZ DEFAULT NOW(),
list_name TEXT DEFAULT 'default', -- users can organize into lists
notes TEXT,

    -- Context
    source              TEXT,                             -- 'search', 'feed', 'friend_profile', 'event', 'concierge'
    session_id          UUID,
    occasion_intent     TEXT,                             -- what occasion they were saving it for
    converted_to_visit  BOOLEAN DEFAULT FALSE,            -- did they actually go?
    converted_at        TIMESTAMPTZ,
    UNIQUE (user_id, restaurant_id)

);

-- ============================================================
-- EVENTS (Group Dining)
-- ============================================================
CREATE TABLE events (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
creator_id UUID REFERENCES users(id) ON DELETE CASCADE,
title TEXT,
occasion TEXT, -- 'birthday', 'casual', 'date_night', 'business'
scheduled_at TIMESTAMPTZ,
group_size_target INT,
status TEXT DEFAULT 'planning', -- 'planning', 'confirmed', 'completed', 'cancelled'
chosen_restaurant_id UUID REFERENCES restaurants(id),
opentable_booking_id TEXT, -- once booked via OpenTable
created_at TIMESTAMPTZ DEFAULT NOW(),
updated_at TIMESTAMPTZ DEFAULT NOW(),

    -- AI signal: capture the decision journey
    dietary_constraints_merged TEXT[],                    -- union of all attendees' dietary needs
    budget_range        TEXT,
    neighbourhood_preference TEXT,
    cuisine_preference  TEXT[]

);

-- ============================================================
-- EVENT ATTENDEES
-- ============================================================
CREATE TABLE event_attendees (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
event_id UUID REFERENCES events(id) ON DELETE CASCADE,
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
status TEXT DEFAULT 'invited', -- 'invited', 'accepted', 'declined'
invite_source TEXT, -- 'in_app', 'link', 'contact'
responded_at TIMESTAMPTZ,
created_at TIMESTAMPTZ DEFAULT NOW(),
UNIQUE (event_id, user_id)
);

-- ============================================================
-- EVENT RESTAURANT CANDIDATES
-- ============================================================
-- This is one of the most valuable AI signal tables
-- Captures what was considered, not just what was chosen
CREATE TABLE event_restaurant_candidates (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
event_id UUID REFERENCES events(id) ON DELETE CASCADE,
restaurant_id UUID REFERENCES restaurants(id) ON DELETE CASCADE,
suggested_by UUID REFERENCES users(id),
was_chosen BOOLEAN DEFAULT FALSE,
rejection_reason TEXT, -- 'too_far', 'too_expensive', 'dietary', 'vibe'
vote_count INT DEFAULT 0,
created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- BEHAVIORAL EVENTS (Raw Signal Layer)
-- ============================================================
-- Every meaningful user action — the foundation of the taste graph
CREATE TABLE behavioral_events (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
event_type TEXT NOT NULL,
-- Examples: 'restaurant_viewed', 'search_performed', 'feed_scrolled',
-- 'profile_visited', 'event_created', 'concierge_queried'

    -- What they interacted with
    restaurant_id       UUID REFERENCES restaurants(id) ON DELETE SET NULL,
    review_id           UUID REFERENCES reviews(id) ON DELETE SET NULL,
    event_id            UUID REFERENCES events(id) ON DELETE SET NULL,
    target_user_id      UUID REFERENCES users(id) ON DELETE SET NULL,

    -- Session context
    session_id          UUID NOT NULL,
    timestamp           TIMESTAMPTZ DEFAULT NOW(),
    time_of_day         TEXT,
    day_of_week         INT,
    device_type         TEXT,                             -- 'ios', 'android'

    -- Where in the app
    source_screen       TEXT,                             -- 'feed', 'search', 'restaurant_page', 'event', 'concierge'
    source_position     INT,                              -- position in list (1st result vs 5th result matters)

    -- Additional metadata (flexible)
    metadata            JSONB
    -- Examples:
    -- search query: {"query": "cozy italian", "results_count": 12}
    -- restaurant view: {"time_spent_seconds": 45, "photos_viewed": 3}
    -- feed scroll: {"items_seen": 8, "scroll_depth": 0.6}

);

-- ============================================================
-- SEARCH QUERIES
-- ============================================================
CREATE TABLE search_queries (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
query_text TEXT NOT NULL,
query_type TEXT, -- 'restaurant', 'dish', 'cuisine', 'neighbourhood'
results_count INT,
clicked_result_id UUID, -- what they actually chose
clicked_position INT, -- where in results they clicked
session_id UUID,
timestamp TIMESTAMPTZ DEFAULT NOW(),
location_at_query GEOGRAPHY(Point, 4326),

    -- AI layer
    query_embedding     vector(1536)                      -- semantic meaning of what they searched

);

-- ============================================================
-- CONCIERGE CONVERSATIONS
-- ============================================================
CREATE TABLE concierge_sessions (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID REFERENCES users(id) ON DELETE CASCADE,
started_at TIMESTAMPTZ DEFAULT NOW(),
ended_at TIMESTAMPTZ,
resulted_in_save BOOLEAN DEFAULT FALSE,
resulted_in_event BOOLEAN DEFAULT FALSE,
resulted_in_booking BOOLEAN DEFAULT FALSE,
city TEXT
);

CREATE TABLE concierge_messages (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
session_id UUID REFERENCES concierge_sessions(id) ON DELETE CASCADE,
role TEXT NOT NULL, -- 'user' or 'assistant'
content TEXT NOT NULL,
restaurants_surfaced UUID[], -- what restaurants were recommended
created_at TIMESTAMPTZ DEFAULT NOW(),

    -- AI layer
    intent_detected     TEXT,                             -- 'find_restaurant', 'get_info', 'book_table'
    context_extracted   JSONB,
    -- {"occasion": "date_night", "group_size": 2, "cuisine": "japanese", "budget": "mid"}
    embedding           vector(1536)

);

-- ============================================================
-- USER TASTE PROFILE (Computed, Updated Periodically)
-- ============================================================
CREATE TABLE user_taste_profiles (
id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
user_id UUID UNIQUE REFERENCES users(id) ON DELETE CASCADE,
computed_at TIMESTAMPTZ DEFAULT NOW(),
signal_count INT DEFAULT 0, -- how many behavioral events fed this
confidence FLOAT DEFAULT 0.0, -- 0 to 1

    -- Derived preferences
    top_cuisines        TEXT[],
    top_neighbourhoods  TEXT[],
    price_tendency      TEXT,
    avg_group_size      FLOAT,
    top_occasions       TEXT[],
    atmosphere_affinity JSONB,                            -- {'cozy': 0.8, 'trendy': 0.3, 'quiet': 0.7}
    dietary_profile     TEXT[],

    -- Social signals
    most_influential_friends UUID[],                      -- whose saves/reviews align with theirs most

    -- AI layer
    taste_embedding     vector(1536),
    profile_summary     TEXT                              -- natural language summary for concierge context

);

-- ============================================================
-- INDEXES (Performance + AI Query Speed)
-- ============================================================

-- Standard indexes
CREATE INDEX idx_behavioral_events_user ON behavioral_events(user_id, timestamp DESC);
CREATE INDEX idx_behavioral_events_type ON behavioral_events(event_type, timestamp DESC);
CREATE INDEX idx_restaurant_saves_user ON restaurant_saves(user_id, created_at DESC);
CREATE INDEX idx_reviews_restaurant ON reviews(restaurant_id, created_at DESC);
CREATE INDEX idx_reviews_user ON reviews(user_id, created_at DESC);
CREATE INDEX idx_event_candidates_event ON event_restaurant_candidates(event_id);
CREATE INDEX idx_search_queries_user ON search_queries(user_id, timestamp DESC);
CREATE INDEX idx_concierge_messages_session ON concierge_messages(session_id, created_at ASC);

-- Vector indexes (for fast similarity search)
CREATE INDEX idx_restaurants_embedding ON restaurants
USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

CREATE INDEX idx_users_taste_embedding ON users
USING ivfflat (taste_embedding vector_cosine_ops) WITH (lists = 100);

CREATE INDEX idx_reviews_embedding ON reviews
USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

CREATE INDEX idx_dishes_embedding ON dishes
USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100);

-- ============================================================
-- EXAMPLE: AI Concierge Query
-- Find restaurants semantically similar to a user's request
-- filtered by their personal taste embedding
-- ============================================================

-- SELECT
-- r.id,
-- r.name,
-- r.neighbourhood,
-- r.price_range,
-- 1 - (r.embedding <=> query_embedding) AS relevance_score,
-- 1 - (r.embedding <=> u.taste_embedding) AS taste_match_score
-- FROM restaurants r
-- CROSS JOIN users u
-- WHERE u.id = :user_id
-- ORDER BY
-- (1 - (r.embedding <=> query_embedding)) _ 0.5 +
-- (1 - (r.embedding <=> u.taste_embedding)) _ 0.5
-- DESC
-- LIMIT 5;
