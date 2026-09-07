/* l4d2_join_rescue — put a human who lands in the spectators back among the survivors.
 *
 * WHY THIS EXISTS. On 2026-08-23 a player could not get into a game for a
 * quarter of an hour while three other people waited. The server log said the
 * same thing on every attempt:
 *
 *     FinishClientPutInServer a player: looking for bots to take over
 *     "a player" entered the game
 *     "a player" joined team "Spectator"
 *
 * She connected perfectly well; the engine's own bot-takeover simply did not
 * fire for her, and there was a survivor bot standing right there holding the
 * slot. The line above it — "Skipping saved player a player - restore was
 * already done" — is the clue: the campaign's saved-player record for her was
 * already consumed, so the game had nothing to restore her into and dropped her
 * to Spectator. Reloading the map did not help; it happened again on the next
 * connect. What fixed it was her typing `jointeam 2` in her own console, which
 * needs the developer console enabled and a person who knows the incantation.
 *
 * A server should not require that of its players. So: if a human is sitting in
 * Spectator shortly after joining, and a survivor bot exists for them to take
 * over, ask the game to put them on the survivor team — exactly the command
 * that worked by hand.
 *
 * IT IS DELIBERATELY TIMID, because the last plugin written here crashed the
 * server twice during a live game:
 *   - it waits, so the engine's own takeover gets first refusal;
 *   - it acts only on a human who is in Spectator and only if a survivor bot is
 *     actually there to be taken over;
 *   - it tries twice per connection and then gives up for good, rather than
 *     looping against a player who wants to spectate;
 *   - it runs in co-op only, where "everyone is a survivor" is the whole point;
 *   - it never touches models, entities or anything that killed us last time.
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define TEAM_SPECTATOR 1
#define TEAM_SURVIVOR  2

/* Long enough that the engine has certainly finished its own attempt: the log
 * above shows "entered the game" and "joined team Spectator" two seconds apart. */
#define FIRST_TRY 4.0
#define RETRY     5.0

public Plugin myinfo =
{
    name        = "L4D2 join rescue",
    author      = "heyvaldemar",
    description = "Rescue a human stuck in spectators when a survivor bot is free",
    version     = "1.0",
    url         = "https://github.com/heyvaldemar/l4d2-server-docker-compose"
};

int g_iTries[MAXPLAYERS + 1];

public void OnClientPutInServer(int client)
{
    g_iTries[client] = 0;
    if (IsFakeClient(client))
        return;
    CreateTimer(FIRST_TRY, Timer_Rescue, GetClientUserId(client),
                TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    g_iTries[client] = 0;
}

static bool InCoop()
{
    char mode[32];
    ConVar cv = FindConVar("mp_gamemode");
    if (cv == null)
        return true;                       /* unknown: do not stand in the way */
    cv.GetString(mode, sizeof(mode));
    return StrEqual(mode, "coop", false) || StrEqual(mode, "realism", false);
}

/* A survivor bot is what makes a takeover possible at all. Without one there is
 * no free slot, and asking for the team would be noise. */
static bool FreeSurvivorBot()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i)
            && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
            return true;
    }
    return false;
}

public Action Timer_Rescue(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
        return Plugin_Stop;
    if (GetClientTeam(client) != TEAM_SPECTATOR)
        return Plugin_Stop;                /* the engine managed it after all */
    if (!InCoop() || !FreeSurvivorBot())
        return Plugin_Stop;
    if (g_iTries[client] >= 2)
    {
        /* Said once, in our own log, so a recurrence is visible without anyone
         * having to be in the game to notice it. */
        LogMessage("l4d2_join_rescue: gave up on %N — still spectating after two tries",
                   client);
        return Plugin_Stop;
    }

    g_iTries[client]++;
    FakeClientCommand(client, "jointeam 2");
    LogMessage("l4d2_join_rescue: moved %N to the survivors (attempt %d)",
               client, g_iTries[client]);
    CreateTimer(RETRY, Timer_Rescue, userid, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}
