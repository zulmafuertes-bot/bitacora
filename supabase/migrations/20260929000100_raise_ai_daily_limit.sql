create or replace function public.consume_ai_request()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  requests_today integer;
begin
  if current_user_id is null then
    raise exception 'Authentication required';
  end if;

  insert into private.ai_daily_usage (user_id, usage_date, request_count)
  values (current_user_id, current_date, 1)
  on conflict (user_id, usage_date)
  do update set request_count = private.ai_daily_usage.request_count + 1
  where private.ai_daily_usage.request_count < 100
  returning request_count into requests_today;

  if requests_today is null then
    raise exception 'Daily AI request limit reached';
  end if;
  return requests_today;
end;
$$;