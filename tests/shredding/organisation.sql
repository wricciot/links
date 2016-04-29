DROP TABLE IF EXISTS contacts;
DROP TABLE IF EXISTS departments;
DROP TABLE IF EXISTS employees;
DROP TABLE IF EXISTS tasks;

CREATE TABLE contacts (
    id     integer primary key,
    dept   text,
    name   text,
    client boolean
) WITH OIDS;

CREATE TABLE departments (
    id     integer primary key,
    name   text
) WITH OIDS;

CREATE TABLE employees (
    id     integer primary key,
    dept   text,
    name   text,
    salary integer
) WITH OIDS;

CREATE TABLE tasks (
    id       integer primary key,
    employee text,
    task     text
) WITH OIDS;