---------------------------------------------------------------------------
-- BASE TYPES
---------------------------------------------------------------------------

DROP DOMAIN IF EXISTS amount_type CASCADE;
CREATE DOMAIN amount_type AS NUMERIC(16, 8) CHECK (VALUE < 21000000 AND VALUE >= 0);
DROP DOMAIN IF EXISTS hash_type CASCADE;
CREATE DOMAIN hash_type AS VARCHAR(95);  -- 32*3 because "aa 0f ca ..."
DROP DOMAIN IF EXISTS address_type CASCADE;
CREATE DOMAIN address_type AS VARCHAR(110);

CREATE OR REPLACE FUNCTION internal_to_sql(value BIGINT) RETURNS amount_type AS $$
    BEGIN
        RETURN value / CAST(100000000 AS NUMERIC(17, 8));
    END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sql_to_internal(value amount_type) RETURNS BIGINT AS $$
    BEGIN
        RETURN CAST(value * 100000000 AS BIGINT);
    END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------
-- DIFFICULTY
---------------------------------------------------------------------------

-- 26959535291011309493156476344723991336010898738574164086137773096960 
-- That's the maximum target and the maximum difficulty

DROP DOMAIN IF EXISTS target_type CASCADE;
CREATE DOMAIN target_type AS NUMERIC(68, 0) CHECK (VALUE <= 26959535291011309493156476344723991336010898738574164086137773096960 AND VALUE >= 0);

CREATE OR REPLACE FUNCTION extract_target(bits_head INT, bits_body INT) RETURNS target_type AS $$
    BEGIN
        RETURN bits_body * (2^(8*(CAST(bits_head AS target_type) - 3)));
    END;
$$ LANGUAGE plpgsql;

DROP DOMAIN IF EXISTS difficulty_type CASCADE;
CREATE DOMAIN difficulty_type AS NUMERIC(76, 8) CHECK (VALUE <= 26959535291011309493156476344723991336010898738574164086137773096960 AND VALUE > 0);

CREATE OR REPLACE FUNCTION difficulty(bits_head INT, bits_body INT) RETURNS difficulty_type AS $$
    BEGIN
        RETURN extract_target(CAST(x'1d' AS INT), CAST(x'00ffff' AS INT)) / extract_target(bits_head, bits_body);
    END;
$$ LANGUAGE plpgsql;

---------------------------------------------------------------------------
-- BLOCKS
---------------------------------------------------------------------------

DROP TABLE IF EXISTS blocks;
DROP SEQUENCE IF EXISTS blocks_block_id_sequence;
DROP SEQUENCE IF EXISTS blocks_space_sequence;
DROP TYPE IF EXISTS block_status_type;

CREATE SEQUENCE blocks_block_id_sequence;
CREATE SEQUENCE blocks_space_sequence;
-- Space 0 is always reserved for the main chain.
-- Other spaces contain orphan chains

CREATE TYPE block_status_type AS ENUM (
    'orphan',
    'valid'
);

CREATE TABLE blocks (
    block_id INT NOT NULL DEFAULT NEXTVAL('blocks_block_id_sequence') PRIMARY KEY,
    block_hash hash_type NOT NULL UNIQUE,
    space INT NOT NULL,
    depth INT NOT NULL,
    span_left INT NOT NULL,
    span_right INT NOT NULL,
    version BIGINT NOT NULL,
    prev_block_id INT,
    prev_block_hash hash_type NOT NULL,
    merkle hash_type NOT NULL,
    when_created TIMESTAMP NOT NULL,
    bits_head INT NOT NULL,
    bits_body INT NOT NULL,
    nonce BIGINT NOT NULL,
    when_found TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    status block_status_type NOT NULL DEFAULT 'orphan'
);

-- Genesis block
INSERT INTO blocks (
    block_hash,
    space,
    depth,
    span_left,
    span_right,
    version,
    prev_block_hash,
    merkle,
    when_created,
    bits_head,
    bits_body,
    nonce,
    status
) VALUES (
    '00 00 00 00 00 19 d6 68 9c 08 5a e1 65 83 1e 93 4f f7 63 ae 46 a2 a6 c1 72 b3 f1 b6 0a 8c e2 6f',
    0,
    0,
    0,
    0,
    1,
    '00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00',
    '4a 5e 1e 4b aa b8 9f 3a 32 51 8a 88 c3 1b c8 7f 61 8f 76 67 3e 2c c7 7a b2 12 7b 7a fd ed a3 3b',
    TO_TIMESTAMP(1231006505),
    29,
    65535,
    2083236893,
    'valid'
);

CREATE INDEX ON blocks USING btree (block_hash);
CREATE INDEX ON blocks (space);
CREATE INDEX ON blocks (depth);

DROP TABLE IF EXISTS chains;
DROP VIEW IF EXISTS main_chain;

CREATE TABLE chains (
    work difficulty_type NOT NULL,
    chain_id INT NOT NULL,
    depth INT NOT NULL
);

INSERT INTO chains (
    work,
    chain_id,
    depth
) SELECT
    difficulty(bits_head, bits_body),
    0,
    0
FROM blocks
WHERE block_id=1;

CREATE VIEW main_chain AS
    WITH main_chain_id AS (
        SELECT 
            chain_id, 
            depth
        FROM chains
        ORDER BY work DESC
        LIMIT 1
    )
    SELECT blocks.*
    FROM blocks, main_chain_id
    WHERE
        space=0
        AND blocks.depth <= main_chain_id.depth
        AND span_left >= chain_id
        AND span_right <= chain_id;

---------------------------------------------------------------------------
-- INVENTORY QUEUE
---------------------------------------------------------------------------

DROP TABLE IF EXISTS inventory_requests;
DROP SEQUENCE IF EXISTS inventory_requests_inventory_id_sequence;
DROP TYPE IF EXISTS inventory_type;

CREATE SEQUENCE inventory_requests_inventory_id_sequence;

CREATE TYPE inventory_type AS ENUM ('block', 'transaction');

CREATE TABLE inventory_requests (
    inventory_id INT NOT NULL DEFAULT NEXTVAL('inventory_requests_inventory_id_sequence') PRIMARY KEY,
    type inventory_type NOT NULL,
    hash hash_type NOT NULL,
    when_discovered TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

---------------------------------------------------------------------------
-- TRANSACTIONS
---------------------------------------------------------------------------

DROP TABLE IF EXISTS transactions;
DROP TABLE IF EXISTS transactions_parents;
DROP TABLE IF EXISTS outputs;
DROP TABLE IF EXISTS inputs;
DROP TABLE IF EXISTS spends;
DROP SEQUENCE IF EXISTS transactions_transaction_id_sequence;
DROP SEQUENCE IF EXISTS outputs_output_id_sequence;
DROP SEQUENCE IF EXISTS inputs_input_id_sequence;
DROP TYPE IF EXISTS output_transaction_type;

-- Block 91842 contains the same coinbase as block 91812
-- Same for blocks 91880 and 91722
-- We use this function to create new txs.
DROP FUNCTION IF EXISTS insert_transaction(hash_type, BIGINT, BIGINT);
CREATE OR REPLACE FUNCTION insert_transaction(tx_hash hash_type, tx_version BIGINT, tx_locktime BIGINT)
RETURNS INT AS $$
DECLARE
 retval INT;
BEGIN
    INSERT INTO transactions(transaction_hash, version, locktime) VALUES (tx_hash, tx_version, tx_locktime) RETURNING transaction_id INTO retval;
    RETURN retval;

    EXCEPTION
        WHEN unique_violation THEN
            RETURN 0;
END;
$$ LANGUAGE plpgsql;

CREATE SEQUENCE transactions_transaction_id_sequence;
CREATE SEQUENCE outputs_output_id_sequence;
CREATE SEQUENCE inputs_input_id_sequence;

CREATE TYPE output_transaction_type AS ENUM ('normal', 'generate', 'other');

CREATE TABLE transactions_parents (
    transaction_id INT NOT NULL,
    block_id INT NOT NULL,
    index_in_block INT NOT NULL
);

CREATE INDEX ON transactions_parents (transaction_id);
CREATE INDEX ON transactions_parents (block_id);

CREATE TABLE transactions (
    transaction_id INT NOT NULL DEFAULT NEXTVAL('transactions_transaction_id_sequence') PRIMARY KEY,
    transaction_hash hash_type NOT NULL UNIQUE,
    version BIGINT NOT NULL,
    locktime BIGINT NOT NULL,
    when_found TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE outputs (
    output_id INT NOT NULL DEFAULT NEXTVAL('outputs_output_id_sequence') PRIMARY KEY,
    transaction_id INT NOT NULL,
    index_in_parent BIGINT NOT NULL,
    script_id INT NOT NULL,
    value amount_type NOT NULL,
    output_type output_transaction_type NOT NULL,
    address address_type
);

CREATE INDEX ON outputs (transaction_id);

CREATE TABLE inputs (
    input_id INT NOT NULL DEFAULT NEXTVAL('inputs_input_id_sequence') PRIMARY KEY,
    transaction_id INT NOT NULL,
    index_in_parent INT NOT NULL,
    script_id INT NOT NULL,
    previous_output_hash hash_type NOT NULL,
    previous_output_index BIGINT NOT NULL,
    sequence BIGINT NOT NULL
);

CREATE INDEX ON inputs (transaction_id);
CREATE INDEX ON inputs (previous_output_hash);

-- We can find all unspent ouputs using:
-- SELECT a.* FROM a LEFT JOIN b ON a.id = b.id WHERE b.id IS NULL;
CREATE TABLE spends (
    output_id INT NOT NULL,
    input_id INT NOT NULL,
    block_id INT NOT NULL
);

CREATE INDEX ON spends (output_id);

---------------------------------------------------------------------------
-- SCRIPTS
---------------------------------------------------------------------------

-- use sequence for script_id

DROP TABLE IF EXISTS operations;
DROP SEQUENCE IF EXISTS operations_script_id_sequence;
DROP SEQUENCE IF EXISTS script_sequence;
DROP TYPE IF EXISTS opcode_type;
DROP TYPE IF EXISTS parent_ident_type;

CREATE SEQUENCE operations_script_id_sequence;
CREATE SEQUENCE script_sequence;

CREATE TYPE opcode_type AS ENUM (
    'special',
    'pushdata1',
    'pushdata2',
    'pushdata4',
    'nop',
    'dup',
    'hash160',
    'equalverify',
    'checksig'
);
CREATE TYPE parent_ident_type AS ENUM ('input', 'output');

CREATE TABLE operations (
    operation_id INT NOT NULL DEFAULT NEXTVAL('operations_script_id_sequence') PRIMARY KEY,
    script_id INT NOT NULL,
    opcode opcode_type NOT NULL,
    data varchar(255)
);

CREATE INDEX ON operations (script_id);
