/*******************************************************************************
 * TRIGGER: TRG_AUTO_IMPORT_OFX_BRADESCO
 * Detecta o fim do upload do OFX (</OFX>) e chama a procedure de importacao.
 * Autor: Sergio Cerqueira - CSB
 *
 * Em vez de uma lista fixa de contas, filtra pelo BANCO da conta
 * (via banco_estabelecimento): processa os bancos cujo OFX a rotina
 * NATIVA do Tasy nao le corretamente. Assim, qualquer conta nova desses
 * bancos passa a importar sozinha, sem mexer no codigo.
 *
 *   cd_banco: 1=Banco do Brasil | 4=Banco do Nordeste | 104=Caixa |
 *             136=Unicred | 237=Bradesco | 748=Sicredi
 *   (999 = Fundo Fixo e caixa interno, nao tem OFX -> fica de fora)
 *
 * Para incluir um banco novo, basta adicionar o codigo na linha
 *   IF v_cd_banco IN (...) THEN
 *
 * Seguranca: a procedure apaga o staging (w_interf_concil) ao final, entao
 * a rotina nativa nao chega a reprocessar essas contas -> nao duplica.
 ******************************************************************************/

CREATE OR REPLACE TRIGGER TRG_AUTO_IMPORT_OFX_BRADESCO
AFTER INSERT ON W_INTERF_CONCIL
FOR EACH ROW
DECLARE
    PRAGMA AUTONOMOUS_TRANSACTION;
    v_nr_extrato     NUMBER;
    v_cd_banco       NUMBER;
    v_saldo_anterior NUMBER;
    v_saldo_final    NUMBER;
BEGIN
    -- Dispara apenas quando o upload do OFX termina
    IF UPPER(:NEW.ds_conteudo) LIKE '%</OFX>%' THEN

        -- Descobre o banco da conta (tabela que ja existe no Tasy)
        BEGIN
            SELECT cd_banco INTO v_cd_banco
            FROM   banco_estabelecimento
            WHERE  nr_sequencia = :NEW.nr_seq_conta;
        EXCEPTION
            WHEN OTHERS THEN v_cd_banco := NULL;
        END;

        -- Bancos cujo OFX usa a importacao customizada (todos os bancos reais da base)
        IF v_cd_banco IN (1, 4, 104, 136, 237, 748) THEN
            BEGIN
                -- Ultimo extrato criado hoje e ainda nao processado
                SELECT MAX(nr_sequencia)
                INTO   v_nr_extrato
                FROM   banco_extrato
                WHERE  nr_seq_conta = :NEW.nr_seq_conta
                  AND  dt_atualizacao >= TRUNC(SYSDATE)
                  AND  vl_saldo_final IS NULL;

                IF v_nr_extrato IS NOT NULL THEN
                    IMPORTA_EXTRATO_OFX_BRADESCO(
                        nr_seq_extrato_p    => v_nr_extrato,
                        cd_saldo_anterior_p => v_saldo_anterior,
                        cd_saldo_final_p    => v_saldo_final
                    );
                    COMMIT;
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    NULL; -- nao propagar erro para nao travar o upload
            END;
        END IF;
    END IF;
END TRG_AUTO_IMPORT_OFX_BRADESCO;
/

SHOW ERRORS;
