/*******************************************************************************
 * PROCEDURE: IMPORTA_EXTRATO_OFX_BRADESCO
 * Importa extratos bancários do Bradesco no formato OFX para o TASY
 * Autor: Sérgio Cerqueira - CSB
 * Data: 17/12/2025
 ******************************************************************************/

CREATE OR REPLACE PROCEDURE IMPORTA_EXTRATO_OFX_BRADESCO(
    nr_seq_extrato_p IN NUMBER,
    cd_saldo_anterior_p OUT NUMBER,
    cd_saldo_final_p OUT NUMBER
) IS
    nr_seq_conta_w          NUMBER(10);
    cd_banco_w              NUMBER(3);
    vl_saldo_inicial_w      NUMBER(15,2) := 0;
    vl_saldo_final_w        NUMBER(15,2) := 0;
    dt_saldo_inicial_w      DATE;
    dt_saldo_final_w        DATE;
    dt_lancamento_w         DATE;
    vl_lancamento_w         NUMBER(15,2);
    ie_deb_cred_w           VARCHAR2(1);
    nr_documento_w          VARCHAR2(50);
    ds_historico_w          VARCHAR2(200);
    cd_historico_w          VARCHAR2(10);
    v_linha                 CLOB;
    v_em_transacao          BOOLEAN := FALSE;
    v_count_lancamentos     NUMBER := 0;
    v_total_credito         NUMBER(15,2) := 0;
    v_total_debito          NUMBER(15,2) := 0;
    v_trntype               VARCHAR2(20);
    v_dtposted              VARCHAR2(20);
    v_trnamt                VARCHAR2(50);
    v_checknum              VARCHAR2(50);
    v_memo                  VARCHAR2(500);
    v_valor_numerico        NUMBER;
    
    CURSOR c_ofx IS
        SELECT ds_conteudo
        FROM w_interf_concil
        WHERE nr_seq_conta = nr_seq_conta_w
        ORDER BY nr_sequencia;

BEGIN
    cd_saldo_anterior_p := NULL;
    cd_saldo_final_p := NULL;
    
    BEGIN
        SELECT b.nr_seq_conta, a.cd_banco
        INTO   nr_seq_conta_w, cd_banco_w
        FROM   banco_estabelecimento a, banco_extrato b
        WHERE  b.nr_seq_conta = a.nr_sequencia
        AND    b.nr_sequencia = nr_seq_extrato_p;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RAISE_APPLICATION_ERROR(-20001, 
                'Extrato ' || nr_seq_extrato_p || ' não encontrado');
    END;

    FOR r_linha IN c_ofx LOOP
        v_linha := TRIM(r_linha.ds_conteudo);
        
        IF v_linha IS NULL OR LENGTH(v_linha) = 0 THEN
            CONTINUE;
        END IF;
        
        IF INSTR(v_linha, '<STMTTRN>') > 0 THEN
            v_em_transacao := TRUE;
            v_trntype := NULL;
            v_dtposted := NULL;
            v_trnamt := NULL;
            v_checknum := NULL;
            v_memo := NULL;
            CONTINUE;
        END IF;
        
        IF v_em_transacao THEN
            IF INSTR(v_linha, '<TRNTYPE>') > 0 THEN
                v_trntype := REGEXP_SUBSTR(v_linha, '<TRNTYPE>(.+)', 1, 1, NULL, 1);
                v_trntype := TRIM(v_trntype);
            END IF;
            
            IF INSTR(v_linha, '<DTPOSTED>') > 0 THEN
                v_dtposted := REGEXP_SUBSTR(v_linha, '<DTPOSTED>(.+)', 1, 1, NULL, 1);
                v_dtposted := TRIM(v_dtposted);
            END IF;
            
            IF INSTR(v_linha, '<TRNAMT>') > 0 THEN
                v_trnamt := REGEXP_SUBSTR(v_linha, '<TRNAMT>(.+)', 1, 1, NULL, 1);
                v_trnamt := TRIM(v_trnamt);
            END IF;
            
            IF INSTR(v_linha, '<CHECKNUM>') > 0 THEN
                v_checknum := REGEXP_SUBSTR(v_linha, '<CHECKNUM>(.+)', 1, 1, NULL, 1);
                v_checknum := TRIM(v_checknum);
            END IF;
            
            IF INSTR(v_linha, '<MEMO>') > 0 THEN
                v_memo := REGEXP_SUBSTR(v_linha, '<MEMO>(.+)', 1, 1, NULL, 1);
                v_memo := TRIM(v_memo);
            END IF;
        END IF;
        
        IF INSTR(v_linha, '</STMTTRN>') > 0 THEN
            v_em_transacao := FALSE;
            
            IF v_dtposted IS NOT NULL AND v_trnamt IS NOT NULL THEN
                BEGIN
                    dt_lancamento_w := TO_DATE(SUBSTR(v_dtposted, 1, 8), 'YYYYMMDD');
                EXCEPTION
                    WHEN OTHERS THEN
                        dt_lancamento_w := SYSDATE;
                END;
                
                BEGIN
                    v_trnamt := REPLACE(v_trnamt, ',', '.');
                    v_valor_numerico := TO_NUMBER(v_trnamt, '9999999999D99', 
                                                   'NLS_NUMERIC_CHARACTERS=''.,''');
                    vl_lancamento_w := ABS(v_valor_numerico);
                    
                    IF v_trntype = 'CREDIT' OR v_valor_numerico > 0 THEN
                        ie_deb_cred_w := 'C';
                        v_total_credito := v_total_credito + vl_lancamento_w;
                    ELSE
                        ie_deb_cred_w := 'D';
                        v_total_debito := v_total_debito + vl_lancamento_w;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        vl_lancamento_w := 0;
                        ie_deb_cred_w := 'C';
                END;
                
                nr_documento_w := NVL(v_checknum, 'OFX-' || TO_CHAR(v_count_lancamentos + 1));
                ds_historico_w := SUBSTR(NVL(v_memo, 'Lançamento OFX'), 1, 200);
                cd_historico_w := SUBSTR(REGEXP_SUBSTR(ds_historico_w, '^[A-Z]+'), 1, 10);
                
                INSERT INTO banco_extrato_lanc (
                    nr_sequencia, 
                    nr_seq_extrato, 
                    dt_movimento, 
                    vl_lancamento,
                    ie_deb_cred, 
                    nr_documento, 
                    ds_historico, 
                    cd_historico,
                    nr_lote, 
                    dt_atualizacao, 
                    nm_usuario, 
                    ie_conciliacao
                ) VALUES (
                    banco_extrato_lanc_seq.NEXTVAL, 
                    nr_seq_extrato_p, 
                    dt_lancamento_w,
                    vl_lancamento_w, 
                    ie_deb_cred_w, 
                    nr_documento_w,
                    ELIMINA_ACENTUACAO(ds_historico_w), 
                    cd_historico_w,
                    'OFX-' || TO_CHAR(SYSDATE, 'YYYYMMDD'), 
                    SYSDATE, 
                    'TASY-OFX', 
                    'N'
                );
                
                v_count_lancamentos := v_count_lancamentos + 1;
                
                IF dt_saldo_inicial_w IS NULL THEN
                    dt_saldo_inicial_w := dt_lancamento_w;
                END IF;
                dt_saldo_final_w := dt_lancamento_w;
            END IF;
        END IF;
        
        IF INSTR(v_linha, '<BALAMT>') > 0 THEN
            BEGIN
                v_trnamt := REGEXP_SUBSTR(v_linha, '<BALAMT>(.+)', 1, 1, NULL, 1);
                v_trnamt := REPLACE(TRIM(v_trnamt), ',', '.');
                vl_saldo_final_w := TO_NUMBER(v_trnamt, '9999999999D99', 
                                               'NLS_NUMERIC_CHARACTERS=''.,''');
            EXCEPTION
                WHEN OTHERS THEN
                    NULL;
            END;
        END IF;
    END LOOP;

    IF vl_saldo_final_w = 0 THEN
        vl_saldo_inicial_w := 0;
        vl_saldo_final_w := v_total_credito - v_total_debito;
    ELSE
        vl_saldo_inicial_w := vl_saldo_final_w - v_total_credito + v_total_debito;
    END IF;

    UPDATE banco_extrato
    SET vl_saldo_inicial = vl_saldo_inicial_w,
        vl_saldo_final   = vl_saldo_final_w,
        dt_inicio        = NVL(dt_saldo_inicial_w, SYSDATE),
        dt_final         = NVL(dt_saldo_final_w, SYSDATE),
        dt_atualizacao   = SYSDATE,
        nm_usuario       = 'TASY-OFX'
    WHERE nr_sequencia = nr_seq_extrato_p;

    cd_saldo_anterior_p := vl_saldo_inicial_w;
    cd_saldo_final_p := vl_saldo_final_w;

    DELETE FROM w_interf_concil WHERE nr_seq_conta = nr_seq_conta_w;

    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        cd_saldo_anterior_p := NULL;
        cd_saldo_final_p := NULL;
        ROLLBACK;
        RAISE_APPLICATION_ERROR(-20099, 'Erro ao importar OFX: ' || SQLERRM);
END IMPORTA_EXTRATO_OFX_BRADESCO;
/

SHOW ERRORS;
