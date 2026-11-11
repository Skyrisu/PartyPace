# PartyPace

**Level together without the "wait, which quest are you on?"** PartyPace shows your whole party's quest progress in one compact window, keeps everyone on the same RestedXP step and tells you who actually needs that drop.

Built by a trio of friends leveling together in WoW Forever – because we were tired of comparing quest logs on Discord.

<!-- Screenshots: main window · RestedXP filter · loot upgrade toast · hearthstone tooltip -->

## Features

**Party quest overview**
- One column per player (2–5) with progress bars, `3/8` counters and ✓ for completed objectives
- Color stripe per quest: **red** someone is missing it · **yellow** progress differs · **green** everyone's done
- Quest level in difficulty color, tags for group (`+`), dungeon (`D`) and raid (`R`) quests
- Hover a quest to see every objective for every player
- Header shows each player's level, XP and rested XP at a glance

**RestedXP integration** *(optional)*
- "Only current guide steps": the list shrinks to the quests your current RestedXP step (plus a few steps ahead) actually needs – no more digging through the quest log
- Sorted in guide order, current-step quests are marked
- Without RestedXP, PartyPace simply shows all quests

**Sharing made easy**
- Auto-share: new quests are shared with whoever is missing them
- Shift-click a quest to share it – or, if *you* are the one missing it, to ask a party member to share it
- "Share missing quests" pushes everything your party doesn't have yet

**Missing quest hints**
- When a party member picks up a quest you don't have, you get a short note: shareable, or where to get it (quest giver and zone, if Questie is installed)

**Who needs this?**
- When someone loots gear, everyone's addon checks it against **their own** equipment and reports upgrades: *"[Gloves of the Monkey] → Kurisu +8 Agi"*
- Respects armor types and weapon skills; rough leveling stat weights, not a full sim
- No gear data is sent – only "this is an upgrade for me"

**Hearthstone sync**
- `HS 2/3` in the header – hover for everyone's cooldown and bind location, plus a warning if you're bound to different inns

**Ready? check**
- One click shows everyone's free bag slots, armor durability and hearthstone – before you head out

**Filters**
- Group by zone · only differences · hide completed · hide class, profession and camping quests
- Alt-click hides a quest, Alt+Ctrl-click hides a whole category

## Requirements

- **WoW Forever**
- **Everyone in your party needs PartyPace** – the addon talks to itself via addon messages
- Optional: RestedXP Guides, Questie (quest giver info), ElvUI (PartyPace uses its font and texture)

## Usage

The window shows up automatically when you're in a party. Drag the header to move it, **Ctrl + mouse wheel** to resize, **right-click** the header for all options. You'll also find PartyPace in the addon menu next to the minimap.

| Command | |
|---|---|
| `/pace` | Show / hide the window |
| `/pace ready` | Ready check (bags, durability, hearthstone) |
| `/pace share` | Share all quests your party is missing |
| `/pace guide` | Toggle "only current RestedXP steps" |
| `/pace help` | All commands |

## FAQ

**Does everyone need the addon?**
Yes. Players without PartyPace simply don't show up in the window.

**Does it work in raids?**
PartyPace is built for 2–5 players and hides itself in raids by default. Right-click → *In raids* → *Show my raid group* if you want it there.

**Is it heavy on performance?**
No. Everything is event-driven, there's no per-frame update, and only changes are sent to your party. Messages are paused during combat.

**What does it send to my party?**
Your quest progress, level/XP, hearthstone cooldown and bind location, upgrade results and – only when someone clicks *Ready?* – free bag slots and durability. Nothing leaves your party.

**Found a bug or have an idea?**
Please open an issue – a BugSack error message helps a lot.

## License

All Rights Reserved © Skyrisu. You're welcome to use and tinker with PartyPace for yourself – please don't re-upload it. See [LICENSE](LICENSE).
