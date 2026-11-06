-- Schema for the FDE Task Tracker. Safe to run on every deploy.
-- Runtime credentials are injected by the deployment environment; no secret is
-- stored in this schema file.

CREATE DATABASE IF NOT EXISTS fde_tasks
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE fde_tasks;

CREATE TABLE IF NOT EXISTS tasks (
  id          INT          NOT NULL AUTO_INCREMENT,
  title       VARCHAR(200) NOT NULL,
  description TEXT         NOT NULL,
  completed   BOOLEAN      NOT NULL DEFAULT FALSE,
  created_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY ix_tasks_id (id)
) ENGINE=InnoDB;
