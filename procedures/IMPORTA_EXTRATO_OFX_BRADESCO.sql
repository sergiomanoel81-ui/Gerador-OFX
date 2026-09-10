create or replace PROCEDURE IMPORTA_EXTRATO_OFX_BRADESCO(
    nr_seq_extrato_p     IN  NUMBER,
    cd_saldo_anterior_p  OUT NUMBER,
    cd_saldo_final_p     OUT NUMBER
) IS
    ---------------------------------------------------------------------------
    -- REFATORACAO v2 - Importacao de extrato OFX
    --
    -- Mudancas em relacao a versao original:
    --  1) Parser por BLOCO (nao mais linha-a-linha). Todo o conteudo de
    --     w_interf_concil e concatenado num CLOB e as transacoes sao lidas
    --     entre <STMTTRN> e </STMTTRN>. Imune a:
    --       - tag de valor fechada na mesma linha (<TRNAMT>-55.00</TRNAMT>)
    --       - tag aberta (<TRNAMT>-55.00)
    --       - conteudo fatiado de qualquer forma em DS_CONTEUDO
    --  2) Extracao de tag com [^<]+ (pega so o conteudo, para no proximo '<').
    --  3) Conversao de valor robusta: trata '-55.00', '129932,92',
    --     '1.234,56' (BR) e '1,234.56' (US), com sinal negativo.
    --  4) BALAMT lido SOMENTE dentro de <LEDGERBAL> (ignora AVAILBAL).
    --  5) Saldo inicial calculado a partir do movimento DESTE arquivo
    --     (nao re-soma a tabela inteira -> nao mistura com a rotina nativa).
    --  6) Deduplicacao por FITID (guardado em DS_OBSERVACAO). Sem FITID,
    --     cai para a chave composta antiga. Rodar 2x nao duplica.
    --  7) CHECKNUM gravado em NR_CHEQUE (campo proprio).
    --  8) Erros de valor/data ABORTAM com mensagem (nao gravam 0 em silencio).
    --
    -- IMPORTANTE: testar em homologacao antes de subir para producao.
    ---------------------------------------------------------------------------
    nr_seq_conta_w          NUMBER(10);
    cd_banco_w              NUMBER(3);

    v_ofx                   CLOB;
    v_bloco                 VARCHAR2(32767);
    v_pos                   NUMBER := 1;
    v_ini                   NUMBER;
    v_fim                   NUMBER;

    vl_saldo_inicial_w      NUMBER(15,2) := 0;
    vl_saldo_final_w        NUMBER(15,2) := 0;
    v_saldo_final_ok        BOOLEAN := FALSE;
    v_saldo_inicial_atual   NUMBER(15,2);

    dt_inicio_w             DATE;
    dt_final_w              DATE;
    dt_lancamento_w         DATE;

    vl_lancamento_w         NUMBER(15,2);
    ie_deb_cred_w           VARCHAR2(1);
    nr_documento_w          VARCHAR2(50);
    nr_cheque_w             VARCHAR2(80);
    ds_historico_w          VARCHAR2(200);
    cd_historico_w          VARCHAR2(10);
    ds_observacao_w         VARCHAR2(200);

    v_trntype               VARCHAR2(20);
    v_dtposted              VARCHAR2(30);
    v_trnamt                VARCHAR2(50);
    v_checknum              VARCHAR2(50);
    v_fitid                 VARCHAR2(50);
    v_memo                  VARCHAR2(500);

    v_valor_numerico        NUMBER;
    v_total_credito         NUMBER(15,2) := 0;
    v_total_debito          NUMBER(15,2) := 0;
    v_count_lancamentos     NUMBER := 0;
    v_existe                NUMBER;

    ---------------------------------------------------------------------------
    -- Extrai o conteudo de UMA tag dentro de um texto, parando no proximo '<'.
    ---------------------------------------------------------------------------
    FUNCTION extrai_tag(p_texto IN VARCHAR2, p_tag IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        RETURN TRIM(REGEXP_SUBSTR(p_texto, '<' || p_tag || '>([^<]+)', 1, 1, NULL, 1));
    END;

    ---------------------------------------------------------------------------
    -- Converte texto numerico do OFX para NUMBER, tratando os formatos
    -- BR e US e sinal negativo. Levanta erro se invalido.
    ---------------------------------------------------------------------------
    FUNCTION converte_valor(p_texto IN VARCHAR2) RETURN NUMBER IS
        v        VARCHAR2(60) := TRIM(p_texto);
        v_neg    BOOLEAN;
        v_dot    NUMBER;
        v_com    NUMBER;
        v_num    NUMBER;
    BEGIN
        IF v IS NULL THEN
            RAISE_APPLICATION_ERROR(-20010, 'Valor numerico vazio no OFX');
        END IF;

        v_neg := (INSTR(v, '-') > 0);
        v := REPLACE(REPLACE(v, '-', ''), '+', '');

        v_dot := INSTR(v, '.', -1);   -- ultima ocorrencia de '.'
        v_com := INSTR(v, ',', -1);   -- ultima ocorrencia de ','

        IF v_dot > 0 AND v_com > 0 THEN
            IF v_com > v_dot THEN
                -- formato BR: ponto = milhar, virgula = decimal (1.234,56)
                v := REPLACE(v, '.', '');
                v := REPLACE(v, ',', '.');
            ELSE
                -- formato US: virgula = milhar, ponto = decimal (1,234.56)
                v := REPLACE(v, ',', '');
            END IF;
        ELSIF v_com > 0 THEN
            -- so virgula -> decimal (129932,92)
            v := REPLACE(v, ',', '.');
        END IF;
        -- so ponto, ou sem separador -> ja esta OK

        v_num := TO_NUMBER(v, '9999999999999990D99999',
                           'NLS_NUMERIC_CHARACTERS=''.,''');

        IF v_neg THEN
            v_num := -v_num;
        END IF;
        RETURN v_num;
    END;

    ---------------------------------------------------------------------------
    -- Converte data OFX (YYYYMMDD...) para DATE.
    ---------------------------------------------------------------------------
    FUNCTION converte_data(p_texto IN VARCHAR2) RETURN DATE IS
    BEGIN
        RETURN TO_DATE(SUBSTR(TRIM(p_texto), 1, 8), 'YYYYMMDD');
    END;

BEGIN
    cd_saldo_anterior_p := NULL;
    cd_saldo_final_p := NULL;

    -- Conta e banco do extrato
    BEGIN
        SELECT b.nr_seq_conta, a.cd_banco
        INTO   nr_seq_conta_w, cd_banco_w
        FROM   banco_estabelecimento a, banco_extrato b
        WHERE  b.nr_seq_conta = a.nr_sequencia
        AND    b.nr_sequencia = nr_seq_extrato_p;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001,
                'Extrato ' || nr_seq_extrato_p || ' nao encontrado');
    END;

    -- Saldo inicial ja existente (usado so quando o OFX nao traz saldo)
    BEGIN
        SELECT vl_saldo_inicial
        INTO   v_saldo_inicial_atual
        FROM   banco_extrato
        WHERE  nr_sequencia = nr_seq_extrato_p;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            v_saldo_inicial_atual := NULL;
    END;

    ---------------------------------------------------------------------------
    -- 1) Concatena todo o conteudo do staging num unico CLOB.
    --    Sem separador: reassembla tags eventualmente fatiadas.
    ---------------------------------------------------------------------------
    v_ofx := EMPTY_CLOB();
    FOR r IN (SELECT ds_conteudo
              FROM   w_interf_concil
              WHERE  nr_seq_conta = nr_seq_conta_w
              ORDER  BY nr_sequencia) LOOP
        IF r.ds_conteudo IS NOT NULL THEN
            v_ofx := v_ofx || r.ds_conteudo;
        END IF;
    END LOOP;

    IF v_ofx IS NULL OR DBMS_LOB.GETLENGTH(v_ofx) = 0 THEN
        RAISE_APPLICATION_ERROR(-20004,
            'Nenhum conteudo OFX encontrado para a conta ' || nr_seq_conta_w);
    END IF;

    ---------------------------------------------------------------------------
    -- 2) Saldo final: BALAMT dentro de LEDGERBAL.
    ---------------------------------------------------------------------------
    DECLARE
        v_ini_led NUMBER;
        v_fim_led NUMBER;
        v_bloco_led VARCHAR2(4000);
        v_balamt VARCHAR2(50);
    BEGIN
        v_ini_led := INSTR(v_ofx, '<LEDGERBAL>');
        IF v_ini_led > 0 THEN
            v_fim_led := INSTR(v_ofx, '</LEDGERBAL>', v_ini_led);
            IF v_fim_led = 0 THEN
                v_fim_led := v_ini_led + 200; -- fallback: pega um trecho
            END IF;
            v_bloco_led := SUBSTR(v_ofx, v_ini_led, v_fim_led - v_ini_led);
            v_balamt := extrai_tag(v_bloco_led, 'BALAMT');
            IF v_balamt IS NOT NULL THEN
                vl_saldo_final_w := converte_valor(v_balamt);
                v_saldo_final_ok := TRUE;
            END IF;
        END IF;
    END;

    ---------------------------------------------------------------------------
    -- 3) Datas do periodo (DTSTART / DTEND). Fallback = min/max lancamentos.
    ---------------------------------------------------------------------------
    DECLARE
        v_s VARCHAR2(30);
        v_e VARCHAR2(30);
    BEGIN
        v_s := extrai_tag(v_ofx, 'DTSTART');
        v_e := extrai_tag(v_ofx, 'DTEND');
        IF v_s IS NOT NULL THEN dt_inicio_w := converte_data(v_s); END IF;
        IF v_e IS NOT NULL THEN dt_final_w  := converte_data(v_e); END IF;
    EXCEPTION
        WHEN OTHERS THEN
            dt_inicio_w := NULL;
            dt_final_w  := NULL;
    END;

    ---------------------------------------------------------------------------
    -- 4) Percorre cada bloco <STMTTRN>...</STMTTRN>
    ---------------------------------------------------------------------------
    v_pos := 1;
    LOOP
        v_ini := INSTR(v_ofx, '<STMTTRN>', v_pos);
        EXIT WHEN v_ini = 0;

        v_fim := INSTR(v_ofx, '</STMTTRN>', v_ini);
        EXIT WHEN v_fim = 0;

        v_bloco := SUBSTR(v_ofx, v_ini, (v_fim - v_ini) + LENGTH('</STMTTRN>'));
        v_pos   := v_fim + 1;

        v_trntype  := extrai_tag(v_bloco, 'TRNTYPE');
        v_dtposted := extrai_tag(v_bloco, 'DTPOSTED');
        v_trnamt   := extrai_tag(v_bloco, 'TRNAMT');
        v_checknum := extrai_tag(v_bloco, 'CHECKNUM');
        v_fitid    := extrai_tag(v_bloco, 'FITID');
        v_memo     := extrai_tag(v_bloco, 'MEMO');

        IF v_dtposted IS NULL OR v_trnamt IS NULL THEN
            CONTINUE; -- bloco incompleto, ignora
        END IF;

        -- Data (aborta se invalida)
        BEGIN
            dt_lancamento_w := converte_data(v_dtposted);
        EXCEPTION
            WHEN OTHERS THEN
                RAISE_APPLICATION_ERROR(-20002,
                    'Data invalida no OFX (DTPOSTED=' || v_dtposted || ')');
        END;

        -- Valor (aborta se invalido - nao grava mais 0 em silencio)
        v_valor_numerico := converte_valor(v_trnamt);
        vl_lancamento_w  := ABS(v_valor_numerico);

        IF v_trntype = 'CREDIT' OR v_valor_numerico > 0 THEN
            ie_deb_cred_w := 'C';
        ELSE
            ie_deb_cred_w := 'D';
        END IF;

        -- Movimento DESTE arquivo (para o calculo do saldo)
        IF ie_deb_cred_w = 'C' THEN
            v_total_credito := v_total_credito + vl_lancamento_w;
        ELSE
            v_total_debito  := v_total_debito + vl_lancamento_w;
        END IF;

        nr_cheque_w    := v_checknum;
        nr_documento_w := NVL(v_checknum, NVL(v_fitid,
                              'OFX-' || TO_CHAR(v_count_lancamentos + 1)));
        ds_historico_w := SUBSTR(NVL(v_memo, 'Lancamento OFX'), 1, 200);
        cd_historico_w := SUBSTR(REGEXP_SUBSTR(ds_historico_w, '^[A-Z]+'), 1, 10);
        ds_observacao_w := CASE WHEN v_fitid IS NOT NULL
                                THEN 'FITID:' || v_fitid
                                ELSE NULL END;

        -- Deduplicacao: por FITID quando existir; senao chave composta
        IF v_fitid IS NOT NULL THEN
            SELECT COUNT(*)
            INTO   v_existe
            FROM   banco_extrato_lanc
            WHERE  nr_seq_extrato = nr_seq_extrato_p
            AND    ds_observacao  = ds_observacao_w;
        ELSE
            SELECT COUNT(*)
            INTO   v_existe
            FROM   banco_extrato_lanc
            WHERE  nr_seq_extrato = nr_seq_extrato_p
            AND    dt_movimento   = dt_lancamento_w
            AND    vl_lancamento  = vl_lancamento_w
            AND    nr_documento   = nr_documento_w
            AND    ie_deb_cred    = ie_deb_cred_w;
        END IF;

        IF v_existe = 0 THEN
            INSERT INTO banco_extrato_lanc (
                nr_sequencia,   nr_seq_extrato, dt_movimento,   vl_lancamento,
                ie_deb_cred,    nr_documento,   nr_cheque,      ds_historico,
                cd_historico,   ds_observacao,  cd_banco_origem,
                nr_lote,        dt_atualizacao, nm_usuario,     ie_conciliacao
            ) VALUES (
                banco_extrato_lanc_seq.NEXTVAL, nr_seq_extrato_p, dt_lancamento_w,
                vl_lancamento_w, ie_deb_cred_w, nr_documento_w,  nr_cheque_w,
                ELIMINA_ACENTUACAO(ds_historico_w), cd_historico_w, ds_observacao_w,
                cd_banco_w,
                'OFX-' || TO_CHAR(SYSDATE, 'YYYYMMDD'), SYSDATE, 'TASY-OFX', 'N'
            );
            v_count_lancamentos := v_count_lancamentos + 1;
        END IF;
    END LOOP;

    ---------------------------------------------------------------------------
    -- 5) Saldos
    ---------------------------------------------------------------------------
    IF v_saldo_final_ok THEN
        -- Tem saldo no OFX -> inicial retroativo pelo movimento DESTE arquivo
        vl_saldo_inicial_w := vl_saldo_final_w - v_total_credito + v_total_debito;
    ELSE
        -- Sem saldo no OFX -> parte do saldo inicial existente
        vl_saldo_inicial_w := NVL(v_saldo_inicial_atual, 0);
        vl_saldo_final_w   := vl_saldo_inicial_w + v_total_credito - v_total_debito;
    END IF;

    -- Datas: se nao vieram do periodo, usa min/max dos lancamentos do extrato
    IF dt_inicio_w IS NULL OR dt_final_w IS NULL THEN
        SELECT NVL(dt_inicio_w, MIN(dt_movimento)),
               NVL(dt_final_w,  MAX(dt_movimento))
        INTO   dt_inicio_w, dt_final_w
        FROM   banco_extrato_lanc
        WHERE  nr_seq_extrato = nr_seq_extrato_p;
    END IF;

    UPDATE banco_extrato
    SET vl_saldo_inicial = vl_saldo_inicial_w,
        vl_saldo_final   = vl_saldo_final_w,
        dt_inicio        = NVL(dt_inicio_w, SYSDATE),
        dt_final         = NVL(dt_final_w, SYSDATE),
        dt_atualizacao   = SYSDATE,
        nm_usuario       = 'TASY-OFX'
    WHERE nr_sequencia = nr_seq_extrato_p;

    cd_saldo_anterior_p := vl_saldo_inicial_w;
    cd_saldo_final_p    := vl_saldo_final_w;

    -- Limpa o staging da conta
    DELETE FROM w_interf_concil WHERE nr_seq_conta = nr_seq_conta_w;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        cd_saldo_anterior_p := NULL;
        cd_saldo_final_p := NULL;
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20099, 'Erro ao importar OFX: ' || SQLERRM);
END IMPORTA_EXTRATO_OFX_BRADESCO;
