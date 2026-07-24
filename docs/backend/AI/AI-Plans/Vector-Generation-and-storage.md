The AI (OpenAI, or whatever model you use) takes your data as input and returns a vector or summary. You then take that output and store it in your database. The AI itself has no memory between calls — it's stateless.

**_A concrete example with restaurants_**

You have this in your database:

```
Chez Marie — French bistro in Kensington Market.
Cozy and intimate. Known for duck confit and
natural wines. Great for date nights. $$$.
```

You send that text to OpenAI's embedding API:

```javascript
const response = await openai.embeddings.create({
  model: "text-embedding-3-small",
  input: "Chez Marie — French bistro in Kensington...",
});

const embedding = response.data[0].embedding;
// Returns an array of 1536 numbers like:
// [0.023, -0.891, 0.445, 0.102, ...]

// You then store that back in your database
await db.query(`UPDATE restaurants SET embedding = $1 WHERE id = $2`, [
  embedding,
  restaurantId,
]);
```

That array of numbers is the semantic fingerprint of that restaurant. It lives in your database forever until you regenerate it.

**_What triggers regeneration_**

You don't call the AI on every request. You generate embeddings:

- When a new restaurant is added
- When a restaurant's description changes significantly
- When a user's taste profile reaches a new confidence threshold
- On a scheduled job — maybe weekly for taste profiles

**_The flow for user taste profiles_**

```
User behavior accumulates in behavioral_events
        ↓
Scheduled job runs (daily or weekly)
        ↓
Aggregates signals into a taste summary:
"Prefers Japanese and Italian. Mid to upscale
pricing. Groups of 4-6. Cozy atmospheres.
King West and Ossington neighbourhoods."
        ↓
Sends that summary to OpenAI embedding API
        ↓
Stores returned vector in users.taste_embedding
Updates taste_confidence score
```

**_The flow for the concierge at query time_**

```
User types: "cozy spot for a rainy Sunday with my partner"
        ↓
You send that string to OpenAI embedding API
        ↓
Get back a vector (this happens in milliseconds)
        ↓
Run vector similarity search in your database
comparing that vector against all restaurant embeddings
AND the user's personal taste embedding
        ↓
Return ranked results
        ↓
Send top results + conversation history to Claude/GPT
to generate a natural language response
```

The cost reality
Embedding calls are extremely cheap. Generating an embedding for a restaurant description costs fractions of a cent. The expensive part is the conversational AI response — but that only happens when a user actively uses the concierge.

### The summary

- AI generates the numbers
- You store the numbers
- You query the numbers
- AI never touches your database directly
