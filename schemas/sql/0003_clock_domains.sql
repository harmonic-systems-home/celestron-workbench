-- Clock exchanges and models name their Mac clock domain (plan Prompt 4, ADR 0001).
-- Never edit this file after it is committed; add a new migration instead.

-- Mac times in an exchange come from one receiver run. A session can span
-- several runs, and an imported phone log can carry exchanges answered by an
-- earlier run, so each exchange records the run that answered it. NULL only
-- for rows written before this migration (the receiver stored none).
ALTER TABLE clock_sync ADD COLUMN mac_clock_boot_id TEXT;

-- A model maps one phone clock domain to one Mac clock domain.
ALTER TABLE clock_models ADD COLUMN mac_clock_boot_id TEXT;
ALTER TABLE clock_models ADD COLUMN phone_boot_id TEXT;
