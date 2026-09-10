/*******************************************************************************
 * TRIGGER: TRG_AUTO_IMPORT_OFX_BRADESCO
 * Detecta fim do upload OFX e chama procedure automaticamente
 * Autor: Sérgio Cerqueira - CSB
 * Data: 17/12/2025
 * 
 * CONFIGURAÇÃO: Para adicionar mais contas, edite a linha:
 *   IF :NEW.nr_seq_conta IN (32) THEN
 * Exemplo: IF :NEW.nr_seq_conta IN (32, 10, 13) THEN
 ******************************************************************************/

CREATE OR REPLACE TRIGGER TRG_AUTO_IMPORT_OFX_BRADESCO
AFTER INSERT ON W_INTERF_CONCIL
FOR EACH ROW
DECLARE
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_nr_extrato NUMBER;
    v_saldo_anterior NUMBER;
    v_saldo_final NUMBER;
BEGIN
    -- Contas configuradas para importação OFX Bradesco
    -- Conta 32 = Bradesco - 888 5 - Conta Aplicação INVEST FACIL
    IF :NEW.nr_seq_conta IN (32) THEN
        
        -- Detectar fim do arquivo OFX
        IF UPPER(:NEW.ds_conteudo) LIKE '%</OFX>%' THEN
            
            BEGIN
                -- Buscar último extrato criado hoje (não processado)
                SELECT MAX(nr_sequencia)
                INTO v_nr_extrato
                FROM banco_extrato
                WHERE nr_seq_conta = :NEW.nr_seq_conta
                AND dt_atualizacao >= TRUNC(SYSDATE)
                AND vl_saldo_final IS NULL;
                
                IF v_nr_extrato IS NOT NULL THEN
                    -- Chamar procedure de importação
                    IMPORTA_EXTRATO_OFX_BRADESCO(
                        nr_seq_extrato_p => v_nr_extrato,
                        cd_saldo_anterior_p => v_saldo_anterior,
                        cd_saldo_final_p => v_saldo_final
                    );
                    
                    COMMIT;
                END IF;
                
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- Não propagar erro
            END;
        END IF;
    END IF;
END TRG_AUTO_IMPORT_OFX_BRADESCO;
/

SHOW ERRORS;
