-- Willagrams — make the invite topic private, and say who may read and write it.
--
-- An invite is a Realtime broadcast on `invites:<recipient uuid>` and touches no
-- table, so none of the four table policies in `0001_init.sql` has anything to
-- say about it. Until this migration the topic was a *public* channel, and a
-- public channel is exactly as open as it sounds: the anon key ships inside the
-- app binary, `profiles` is readable by any signed-in player, and a friend code
-- resolves to a uuid. So anyone could build the topic name for anyone else,
-- subscribe to it, and read live `inviteCode`s as they were sent — then join
-- that lobby ahead of the friend it was meant for.
--
-- `ShellModel` already drops an invite whose `hostID` is not an accepted
-- friend, which covers spoofed frames *arriving*. It cannot cover listening,
-- because listening happens on the server and leaves no trace on the client.
-- That half is only fixable here.
--
-- Supabase's answer is Realtime Authorization: a channel that joins with
-- `private: true` has every read and every write checked against RLS policies
-- on `realtime.messages`, with `realtime.topic()` returning the topic being
-- asked about. A public channel skips the check entirely. Both halves are
-- required — `isPrivate` on the client with no policy here denies everything
-- and invites stop working, and policies here with a public channel are never
-- consulted and change nothing. The client half is
-- `SupabaseMatchInviteChannel`, and it lands in the same commit as this file.
--
-- Only `invites:*` is affected. `match:<uuid>` stays a public channel: it is
-- reached only by a player the `security definer` `join_match` already seated,
-- the match id is not derivable from a profile, and turning it private is a
-- second decision with its own two-device test. Nothing below matches its
-- topic, so nothing below can break it.
--
-- No table, column or constraint changes here, and no `public` policy is
-- touched. The shape `FOUNDATION.md` freezes is untouched.

-- ---------------------------------------------------------------------------
-- Reading the recipient out of a topic name.
-- ---------------------------------------------------------------------------

-- `substring(topic from 9)::uuid` cannot be written inline in a policy. A
-- policy is one boolean expression, `and` in SQL does not promise to
-- short-circuit, and a cast of a non-uuid *raises* rather than returning false
-- — so a stranger joining `invites:hello` would get a 500 out of a rule that
-- meant to say no. Null is the answer that means "not an invite topic", and
-- every comparison against it is already false.
--
-- `immutable` and `strict`: the same text always yields the same uuid, and a
-- null topic (no `realtime.topic` set, which is every non-Realtime query that
-- ever touches this table) is null without entering the body.
create or replace function public.invite_topic_recipient(topic text)
returns uuid
language plpgsql
immutable
strict
set search_path = public, pg_temp
as $$
begin
    if topic not like 'invites:%' then
        return null;
    end if;
    return substring(topic from 9)::uuid;
exception when others then
    -- 'invites:' followed by anything that is not a uuid.
    return null;
end $$;

-- `from public` as well as `from anon`, the same pair `0003` and `0004` use:
-- `create function` grants execute to `PUBLIC` by default, and revoking from
-- `anon` does not take away a privilege `anon` holds through `PUBLIC`. Revoking
-- only from `anon` looks right and changes nothing. This function reads no
-- table and tells a caller only whether a string parses, so the exposure would
-- be small — but the habit is what matters, and the two definer functions
-- beside it are where the same slip would not be small.
revoke execute on function public.invite_topic_recipient(text) from public;
revoke execute on function public.invite_topic_recipient(text) from anon;
grant execute on function public.invite_topic_recipient(text) to authenticated;

-- ---------------------------------------------------------------------------
-- The policies themselves.
-- ---------------------------------------------------------------------------

-- Supabase creates `realtime.messages` and enables RLS on it. Stated rather
-- than assumed: a project where it is off is a project where every policy
-- below is decoration.
alter table realtime.messages enable row level security;

-- Reading — you may listen on your own topic and on nobody else's. This is the
-- whole point of the migration: `auth.uid()` is the only uuid that can appear
-- on the right, so there is no topic name a caller can construct that reads
-- someone else's invites.
--
-- `extension = 'broadcast'` keeps this from also granting presence on the same
-- topic. Nothing in the app uses presence on `invites:*`, and a rule that
-- grants a feature nobody asked for is a rule that surprises someone later.
drop policy if exists invites_listen_on_own_topic on realtime.messages;
create policy invites_listen_on_own_topic
    on realtime.messages for select
    to authenticated
    using (
        extension = 'broadcast'
        and realtime.topic() = 'invites:' || auth.uid()::text
    );

-- Writing — you may broadcast onto a topic belonging to someone you are
-- already accepted friends with.
--
-- Note the asymmetry with the read: the sender never gains a read on the
-- recipient's topic, only a write. That is deliberate and it is why the client
-- sends over the REST broadcast endpoint (`httpSend`) instead of joining the
-- channel first — joining is a read, and a sender that had to join would need
-- a select policy that let friends listen to each other's invites, which puts
-- back a smaller version of the hole this migration closes.
--
-- The friendship lookup runs as `authenticated` and so is itself filtered by
-- `friendships_select_own`, which shows a row only to its two ends. That is
-- strictly tighter than what is written here and never looser: the only rows
-- this exists-clause can see are rows `auth.uid()` is an end of, which are the
-- only rows it asks about anyway.
--
-- 'accepted' only. A pending request is not a friendship, and 'blocked' is the
-- opposite of one — neither may put a banner on someone's screen.
drop policy if exists invites_send_to_accepted_friend on realtime.messages;
create policy invites_send_to_accepted_friend
    on realtime.messages for insert
    to authenticated
    with check (
        extension = 'broadcast'
        and exists (
            select 1
            from public.friendships f
            where f.status = 'accepted'
              and (
                  (f.requester_id = auth.uid()
                   and f.addressee_id = public.invite_topic_recipient(realtime.topic()))
               or (f.addressee_id = auth.uid()
                   and f.requester_id = public.invite_topic_recipient(realtime.topic()))
              )
        )
    );
