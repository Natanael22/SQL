create or replace PACKAGE BODY XXARCO_AR_INT_CUSTOMER_PKG AS
    -- +=========================================================================+
    -- |                              ARCO                                       |
    -- |                       All rights reserved.                              |
    -- +=========================================================================+
    -- | FILENAME                                                                |
    -- |   XXARCO_AR_INT_CUSTOMER_PKG.pkb                                    |
    -- |                                                                         |
    -- | PURPOSE                                                                 |
    -- |   Criacao/atualizacao SINCRONA de clientes/fornecedores via JSON        |
    -- |                                                                         |
    -- | CREATED BY                                                              |
    -- |   Natanael Correia            (03/06/2026)        1.0                   |
    -- |   Natanael Correia             14/09/2026         alterado lookup para XXARCO_ORG_RCPT_METHOD e update_contact_point
    -- +=========================================================================+

    -- =========================================================================
    -- TIPO: Registro espelhando os campos da view xxpsd_int_cliente_v
    -- =========================================================================
    TYPE rec_dados_cliente IS RECORD (
        -- Identificacao
        codigoreferencia       VARCHAR2(50),
        nome_cliente           VARCHAR2(360),
        nome_fantasia          VARCHAR2(360),
        tipo_documento         VARCHAR2(4),    -- 'J' = CNPJ, 'F' = CPF
        numero_documento       VARCHAR2(50),
        inscricao_estadual     VARCHAR2(50),
        -- Fiscal
        tipocontribuinte       VARCHAR2(1),    -- 'S' ou 'N'
        natureza_juridica      VARCHAR2(50),
        -- Endereco (SHIP_TO / delivery)
        logradouro             VARCHAR2(360),
        numero                 VARCHAR2(100),
        complemento            VARCHAR2(100),
        bairro                 VARCHAR2(360),
        cep                    VARCHAR2(20),
        cidade                 VARCHAR2(360),
        unidadefederativa      VARCHAR2(10),
        estado                 VARCHAR2(10),
        pais                   VARCHAR2(50),        
        -- Contato
        email                  VARCHAR2(255),
        emailxml               VARCHAR2(255),
        telefone               VARCHAR2(50),
        -- Flags fixos para este fluxo
        transportadora         VARCHAR2(1),    -- sempre 'N'
        codigosuframa          VARCHAR2(50),
        -- Campos auxiliares (nulos para este fluxo)
        tipoendereco           VARCHAR2(50),
        pontoreferencia        VARCHAR2(100),
        cnae                   VARCHAR2(50),
        tipodepartamento       VARCHAR2(50),
        categoria              VARCHAR2(50),
        cobranca               VARCHAR2(50),
        ddi                    VARCHAR2(10),
        ddd                    VARCHAR2(10),
        codigoibge             VARCHAR2(20),
        --ID CGI
        institutionId          VARCHAR(50)--podera vir null ou 6eefbf49-ca3e-42d7-b423-b47e8e8c0515
    );

    -- =========================================================================
    -- CONSTANTES DE CONFIGURACAO
    -- =========================================================================

    -- =========================================================================
    -- VARIAVEIS GLOBAIS DO PACKAGE
    -- =========================================================================
    g_scope_prefix      CONSTANT VARCHAR2(100) := LOWER($$PLSQL_UNIT) || '.';
    g_escopo            VARCHAR2(200)  := NULL;
    g_created_by_module VARCHAR2(100)  := 'TCA_V2_API';

    -- Controles de processamento
    ok                  BOOLEAN;
    w_return_status     VARCHAR2(300);
    w_msg_count         NUMBER;
    w_msg_data          VARCHAR2(4000);

    -- IDs gerados/encontrados durante o processamento
    w_vendor_id         NUMBER;
    w_vendor_site_id    NUMBER;
    w_vendor_site_code  VARCHAR2(50);
    w_party_id          NUMBER;
    w_party_site_id     NUMBER;
    w_party_number      VARCHAR2(100);
    w_location_id       NUMBER;
    w_cust_account_id   NUMBER;
    w_account_number    VARCHAR2(50);
    w_profile_id        NUMBER;
    w_cust_acct_site_id NUMBER;
    w_site_use_id       NUMBER;
    w_nm_cliente        VARCHAR2(300);
    w_qty_vendor        NUMBER := 0;

    -- Derivados do documento
    g_documento         VARCHAR2(20);
    g_documento_inteiro VARCHAR2(50);
    g_documento_raiz    VARCHAR2(9);
    g_documento_filial  VARCHAR2(4);
    g_documento_dv      VARCHAR2(2);
    g_global_attribute9 VARCHAR2(1);

    -- Informacoes fiscais
    g_inscricao_estadual VARCHAR2(100);
    g_tipo_contribuite   VARCHAR2(20);
    g_indicador_ie_dest  VARCHAR2(2);
    g_vendor_type        VARCHAR2(50);
    g_fornec_incluir     VARCHAR2(1) := 'N';

    -- Endereco
    g_country            VARCHAR2(2);
    g_estado             VARCHAR2(50);
    g_cidade             VARCHAR2(50);

    -- Retorno estruturado (reutiliza tipo do package de interface)
    g_rec_retorno        apps.xxpsd_pck_interface_integracao.rec_retorno_integracao;
    
    g_ret_validacao     NUMBER;

    -- =========================================================================
    -- PROCEDIMENTOS PRIVADOS UTILITARIOS
    -- =========================================================================

    -- -------------------------------------------------------------------------
    -- Zera as variaveis globais antes de cada execucao para evitar lixo
    -- -------------------------------------------------------------------------
    PROCEDURE inicializar_variaveis IS
    BEGIN
        ok                  := TRUE;
        w_return_status     := NULL;
        w_msg_count         := 0;
        w_msg_data          := NULL;
        w_vendor_id         := NULL;
        w_vendor_site_id    := NULL;
        w_vendor_site_code  := NULL;
        w_party_id          := NULL;
        w_party_site_id     := NULL;
        w_party_number      := NULL;
        w_location_id       := NULL;
        w_cust_account_id   := NULL;
        w_account_number    := NULL;
        w_profile_id        := NULL;
        w_cust_acct_site_id := NULL;
        w_site_use_id       := NULL;
        w_nm_cliente        := NULL;
        w_qty_vendor        := 0;
        g_documento         := NULL;
        g_documento_inteiro := NULL;
        g_documento_raiz    := NULL;
        g_documento_filial  := NULL;
        g_documento_dv      := NULL;
        g_global_attribute9 := NULL;
        g_inscricao_estadual:= NULL;
        g_tipo_contribuite  := NULL;
        g_indicador_ie_dest := NULL;
        g_vendor_type       := NULL;
        g_country           := NULL;
        g_estado            := NULL;
        g_cidade            := NULL;
        g_ret_validacao     := 0;
        g_fornec_incluir    := 'N';
    END inicializar_variaveis;   

    PROCEDURE print_log(msg IN VARCHAR2) IS
    BEGIN
        DBMS_OUTPUT.PUT_LINE(msg);
        FND_FILE.PUT_LINE(FND_FILE.LOG, msg);
        xxpsd_pck_logger.log_info(p_log => msg, p_escopo => g_escopo);
    END print_log;

    -- -------------------------------------------------------------------------
    PROCEDURE adicionar_erro(p_tipo IN VARCHAR2,
                             p_msg  IN VARCHAR2,
                             p_print BOOLEAN DEFAULT TRUE) IS
        l_count NUMBER;
    BEGIN
        l_count := NVL(g_rec_retorno."registros"(1)."linhas"(1)."mensagens".COUNT, 0) + 1;
        g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(l_count)."tipoMensagem" := p_tipo;
        g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(l_count)."mensagem"     := p_msg;
        IF p_print THEN
            print_log('  ' || p_msg);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            print_log('ERRO[ADD_ERRO]:' || SQLERRM);
    END adicionar_erro;

     -- -------------------------------------------------------------------------
    -- Extrai e loga as mensagens de erro das APIs (FND_MSG_PUB)
    -- -------------------------------------------------------------------------
    PROCEDURE extrair_mensagens_api(p_msg_count NUMBER, p_prefixo VARCHAR2 DEFAULT NULL, p_tipo VARCHAR2 DEFAULT 'ERROR') IS
        l_msg VARCHAR2(4000);
        l_prefix VARCHAR2(100) := CASE WHEN p_prefixo IS NOT NULL THEN p_prefixo || ': ' ELSE '' END;
    BEGIN
        FOR i IN 1 .. NVL(p_msg_count, fnd_msg_pub.count_msg) LOOP
            l_msg := fnd_msg_pub.get(p_msg_index => i, p_encoded => fnd_api.g_false);
            adicionar_erro(p_tipo, l_prefix || l_msg, FALSE);
            print_log('  ' || i || ') ' || l_prefix || l_msg);
        END LOOP;
    END extrair_mensagens_api;
    
    -- -------------------------------------------------------------------------
    -- Padroniza logs de excecao e adiciona ao array de erros (sem parar processo)
    -- -------------------------------------------------------------------------
    PROCEDURE log_exception(p_procedure VARCHAR2, p_contexto VARCHAR2) IS
    BEGIN
        print_log('AVISO [' || p_procedure || ']: ' || p_contexto || ' - ' || SQLERRM);
        adicionar_erro('AVISO', p_procedure || ': ' || SQLERRM, FALSE);
    END log_exception;
    -- -------------------------------------------------------------------------
    PROCEDURE initialize IS
        l_user_id      VARCHAR2(100);
        x_resp_id      NUMBER;
        x_resp_appl_id NUMBER;
    BEGIN
        SELECT attribute2
          INTO x_resp_id
          FROM fnd_lookup_values
         WHERE lookup_type = 'XXARCO_RESP_INTEGRACOES'
           AND lookup_code = 'CRIAR_CLIENTE_EBS'
           AND language    = 'PTB';

        SELECT application_id
          INTO x_resp_appl_id
          FROM fnd_responsibility_vl
         WHERE responsibility_id = x_resp_id;

        SELECT fu.user_id
          INTO l_user_id
          FROM fnd_user fu
         WHERE NVL(fu.end_date, SYSDATE + 1) > SYSDATE
           AND fu.user_name = 'INTEGRACAO';

        mo_global.init('S');
        fnd_global.apps_initialize(l_user_id, x_resp_id, x_resp_appl_id);
    EXCEPTION
        WHEN OTHERS THEN
            ok := FALSE;
            adicionar_erro('ERROR', 'Nao foi possivel iniciar o Ambiente EBS');
            adicionar_erro('ERROR', SQLERRM);
    END initialize;

    -- -------------------------------------------------------------------------
    PROCEDURE init_retorno IS
    BEGIN
        g_rec_retorno."contexto"                     := NULL;
        g_rec_retorno."retornoProcessamento"         := NULL;
        g_rec_retorno."mensagemRetornoProcessamento" := NULL;
        g_rec_retorno."registros".DELETE;
        g_rec_retorno."registros"(1)."tipoCabecalho"           := 'PROCESSAR_CLIENTE_SNC';
        g_rec_retorno."registros"(1)."codigoCabecalho"         := NULL;
        g_rec_retorno."registros"(1)."tipoReferenciaOrigem"    := NULL;
        g_rec_retorno."registros"(1)."codigoReferenciaOrigem"  := NULL;
        g_rec_retorno."registros"(1)."retornoProcessamento"    := NULL;
        g_rec_retorno."registros"(1)."linhas".DELETE;
        g_rec_retorno."registros"(1)."linhas"(1)."tipoLinha"                   := NULL;
        g_rec_retorno."registros"(1)."linhas"(1)."codigoLinha"                 := NULL;
        g_rec_retorno."registros"(1)."linhas"(1)."tipoReferenciaLinhaOrigem"   := NULL;
        g_rec_retorno."registros"(1)."linhas"(1)."codigoReferenciaLinhaOrigem" := NULL;
        g_rec_retorno."registros"(1)."linhas"(1)."mensagens".DELETE;
        g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(1)."tipoMensagem" := NULL;
        g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(1)."mensagem"     := NULL;
    END init_retorno;

    -- =========================================================================
    -- PARSE DO JSON DE ENTRADA
    -- Extrai os campos do payload e popula o record rec_dados_cliente.
    -- Usa JSON_TABLE via SELECT
    -- =========================================================================
    PROCEDURE parse_json(p_json   IN  CLOB,
                         p_dados  OUT rec_dados_cliente) IS
        -- Endereco de cobranca (billing / BILL_TO)
        l_billing_street       VARCHAR2(360);
        l_billing_number       VARCHAR2(100);
        l_billing_complement   VARCHAR2(100);
        l_billing_postal_code  VARCHAR2(20);
        l_billing_neighborhood VARCHAR2(360);
        l_billing_city         VARCHAR2(360);
        l_billing_state        VARCHAR2(10);
        -- Endereco de entrega (delivey / SHIP_TO)
        l_delivery_street       VARCHAR2(360);
        l_delivery_number       VARCHAR2(100);
        l_delivery_complement   VARCHAR2(100);
        l_delivery_postal_code  VARCHAR2(20);
        l_delivery_neighborhood VARCHAR2(360);
        l_delivery_city         VARCHAR2(360);
        l_delivery_state        VARCHAR2(10);
        -- Dados raiz do JSON
        l_doc_number    VARCHAR2(50);
        l_name          VARCHAR2(360);
        l_email         VARCHAR2(255);
        l_is_tax_payer  VARCHAR2(10);
        l_stateTaxId    varchar2(100);--Inscricao Estadual
        l_tradeName     VARCHAR2(360);--Nome Fantasia
        l_institutionId VARCHAR(50); --ID CGI
    BEGIN
        -- 1. Extrai campos raiz
        SELECT jt.school_doc_number,
               jt.name,
               jt.invoice_email,
               jt.is_tax_payer_type,
               jt.stateTaxId,
               jt.tradeName,
               jt.institutionId
          INTO l_doc_number,
               l_name,
               l_email,
               l_is_tax_payer,
               l_stateTaxId,
               l_tradeName,
               l_institutionId
          FROM JSON_TABLE(p_json, '$'
                 COLUMNS (
                     school_doc_number  VARCHAR2(50)  PATH '$.schoolDocNumber',
                     name               VARCHAR2(360) PATH '$.name',
                     invoice_email      VARCHAR2(255) PATH '$.invoiceEmail',
                     is_tax_payer_type  VARCHAR2(10)  PATH '$.isTaxPayerType',
                     stateTaxId         VARCHAR2(100)  PATH '$.stateTaxId',
                     tradeName          VARCHAR2(360)  PATH '$.tradeName',
                     institutionId      VARCHAR(50)    PATH '$.institutionId'
                 )) jt;

        -- 2. Extrai endereco de cobranca (billing = BILL_TO)
        BEGIN
            SELECT jt.street,
                   jt.addr_num,
                   jt.complement,
                   jt.postal_code,
                   jt.neighborhood,
                   jt.city,
                   jt.state
              INTO l_delivery_street,
                   l_delivery_number,
                   l_delivery_complement,
                   l_delivery_postal_code,
                   l_delivery_neighborhood,
                   l_delivery_city,
                   l_delivery_state
              FROM JSON_TABLE(p_json, '$.addresses[*]'
                     COLUMNS (
                         addr_type    VARCHAR2(20)  PATH '$.type',
                         street       VARCHAR2(360) PATH '$.street',
                         addr_num     VARCHAR2(100) PATH '$.number',
                         complement   VARCHAR2(100) PATH '$.complement',
                         postal_code  VARCHAR2(20)  PATH '$.postalCode',
                         neighborhood VARCHAR2(360) PATH '$.neighborhood',
                         city         VARCHAR2(360) PATH '$.city',
                         state        VARCHAR2(10)  PATH '$.state'
                     )) jt
             WHERE LOWER(jt.addr_type) = 'delivery'
               AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- Se nao tiver delivery, tenta billing como fallback
                BEGIN
                    SELECT jt.street,
                           jt.addr_num,
                           jt.complement,
                           jt.postal_code,
                           jt.neighborhood,
                           jt.city,
                           jt.state
                      INTO l_billing_street,
                           l_billing_number,
                           l_billing_complement,
                           l_billing_postal_code,
                           l_billing_neighborhood,
                           l_billing_city,
                           l_billing_state
                      FROM JSON_TABLE(p_json, '$.addresses[*]'
                             COLUMNS (
                                 addr_type    VARCHAR2(20)  PATH '$.type',
                                 street       VARCHAR2(360) PATH '$.street',
                                 addr_num     VARCHAR2(100) PATH '$.number',
                                 complement   VARCHAR2(100) PATH '$.complement',
                                 postal_code  VARCHAR2(20)  PATH '$.postalCode',
                                 neighborhood VARCHAR2(360) PATH '$.neighborhood',
                                 city         VARCHAR2(360) PATH '$.city',
                                 state        VARCHAR2(10)  PATH '$.state'
                             )) jt
                     WHERE ROWNUM = 1;
                EXCEPTION
                    WHEN OTHERS THEN
                        print_log('AVISO: Nao foi possivel extrair endereco do JSON - ' || SQLERRM);
                END;
        END;

        -- 3. Popula record com valores extraidos e fixos
        -- Documento
        l_doc_number              := REGEXP_REPLACE(l_doc_number, '[^a-zA-Z0-9]', ''); -- remove mascara
        p_dados.numero_documento  := l_doc_number;
        p_dados.tipo_documento    := CASE LENGTH(l_doc_number)
                                         WHEN 11 THEN 'CPF'--1206 'F'
                                         WHEN 14 THEN 'CNPJ'--1206 'J'
                                         ELSE          'CNPJ'--1206 'J'
                                     END;
                                   
        -- Identificacao
        p_dados.nome_cliente      := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(TRIM(l_name));
        p_dados.nome_fantasia     := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(TRIM(CASE WHEN l_tradeName IS NULL THEN l_name ELSE l_tradeName END));
        p_dados.codigoreferencia  := l_doc_number;

        -- Contato
        p_dados.email             := l_email;
        p_dados.emailxml          := l_email;
        p_dados.telefone          := NULL; -- fixo nulo conforme decisao

        -- Fiscal
        p_dados.tipocontribuinte  := CASE WHEN LOWER(l_is_tax_payer) IN ('true', '1', 's') THEN 'S' ELSE 'N' END;
        p_dados.inscricao_estadual := CASE WHEN l_stateTaxId IS NOT NULL THEN l_stateTaxId ELSE 'ISENTO' END;    -- fixo conforme decisao
        p_dados.natureza_juridica  := 'COMERCIAL';

        -- Endereco (SHIP_TO)
        p_dados.logradouro        := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(l_delivery_street);
        p_dados.numero            := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(l_delivery_number);
        p_dados.complemento       := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(l_delivery_complement);
        p_dados.cep               := l_delivery_postal_code;
        p_dados.bairro            := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(l_delivery_neighborhood);
        p_dados.cidade            := XXARCO_OM_INT_CAD_CLIENTE_PKG.insensitive_string(l_delivery_city);
        p_dados.unidadefederativa := UPPER(l_delivery_state);
        p_dados.estado            := UPPER(l_delivery_state);
        p_dados.pais              := 'BRASIL'; -- fixo conforme decisao
        -- Flags fixos
        p_dados.transportadora    := 'N';
        p_dados.codigosuframa     := NULL;
        
        p_dados.institutionId     := l_institutionId;

    EXCEPTION
        WHEN OTHERS THEN
            ok := FALSE;
            adicionar_erro('ERROR', 'Falha ao parsear JSON de entrada: ' || SQLERRM);
            RAISE;
    END parse_json;

    -- =========================================================================
    -- VALIDACOES -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================

    FUNCTION recuperar_sigla_pais(p_pais VARCHAR2) RETURN VARCHAR2 IS
        l_result VARCHAR2(2);
    BEGIN
        BEGIN
            SELECT geography_code
              INTO l_result
              FROM hz_geographies
             WHERE geography_type = 'COUNTRY'
               AND UPPER(geography_name) = UPPER(p_pais);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                SELECT DISTINCT territory_code
                  INTO l_result
                  FROM fnd_territories_tl t
                 WHERE UPPER(RTRIM(UTL_RAW.CAST_TO_VARCHAR2((NLSSORT(territory_short_name, 'nls_sort=binary_ai'))), CHR(0))) =
                       UPPER(RTRIM(UTL_RAW.CAST_TO_VARCHAR2((NLSSORT(p_pais, 'nls_sort=binary_ai'))), CHR(0)));
        END;
        RETURN l_result;
    END recuperar_sigla_pais;

    -- -------------------------------------------------------------------------
    FUNCTION validar_estado(p_estado VARCHAR2) RETURN BOOLEAN IS
        l_estado_encontrado NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO l_estado_encontrado
          FROM hz_geographies
         WHERE geography_type = 'STATE'
           AND geography_code  = UPPER(p_estado);

        IF l_estado_encontrado > 0 THEN
            print_log('  Estado encontrado no cadastro : ' || p_estado);
            RETURN TRUE;
        ELSE
            print_log('  ERRO: Estado nao encontrado no cadastro : ' || p_estado);
            ok := FALSE;
            adicionar_erro('ERROR', 'Estado nao encontrado no cadastro: ' || p_estado);
            RETURN FALSE;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            adicionar_erro('ERROR', 'Erro ao validar Estado: ' || SQLERRM, FALSE);
            RETURN FALSE;
    END validar_estado;

    -- -------------------------------------------------------------------------
    FUNCTION validar_cidade(p_cidade VARCHAR2) RETURN BOOLEAN IS
        l_cidade_ok NUMBER;
    BEGIN
        SELECT COUNT(*)
          INTO l_cidade_ok
          FROM hz_geographies hz1,
               hz_geographies hz2,
               hz_geography_identifiers hgi
         WHERE hz1.geography_id      = hz2.geography_element2_id
           AND hz2.geography_id      = hgi.geography_id
           AND hgi.identifier_subtype = 'IBGE'
           AND hz1.geography_type    = 'STATE'
           AND hz2.geography_type    = 'CITY'
           AND hz1.country_code      = 'BR'
           AND UPPER(hz2.geography_name) = UPPER(p_cidade);

        IF l_cidade_ok > 0 THEN
            print_log('  Cidade encontrada no cadastro : ' || p_cidade);
            RETURN TRUE;
        ELSE
            print_log('  ERRO: Cidade nao encontrada no cadastro : ' || p_cidade);
            ok := FALSE;            
            adicionar_erro('ERROR', 'Cidade nao encontrada no cadastro: ' || p_cidade);
            RETURN FALSE;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            adicionar_erro('ERROR', 'Erro ao validar Cidade: ' || SQLERRM, FALSE);
            RETURN FALSE;
    END validar_cidade;

    -- -------------------------------------------------------------------------
    FUNCTION validar_documento(p_tipo_documento   VARCHAR2,
                               p_numero_documento VARCHAR2) RETURN BOOLEAN IS
        l_valida_documento NUMBER;
        -- 1 true / 0 false
        --cll_f189_digit_calc_pkg - 1 SUCESSO / 0 ERRO
    BEGIN
        IF ((p_tipo_documento = 'CPF' AND LENGTH(p_numero_documento) = 11) OR--1206 'F'
            (p_tipo_documento = 'CNPJ' AND LENGTH(p_numero_documento) = 14)) THEN--1206 'J'

            l_valida_documento := cll_f189_digit_calc_pkg.func_doc_validation(p_tipo_documento, p_numero_documento);
            print_log('  Validacao do ' ||p_tipo_documento||' numero do documento: ' || l_valida_documento);
            
            if l_valida_documento = 1 then
                RETURN TRUE;
            else
                ok  := FALSE;
                w_return_status := 'Documento nao informado ou invalido - ' || p_numero_documento;
                adicionar_erro('ERROR', w_return_status);
                RETURN FALSE;
            end if;

        ELSIF p_numero_documento IS NOT NULL THEN

            l_valida_documento := cll_f189_digit_calc_pkg.func_doc_validation(p_tipo_documento, p_numero_documento);
            print_log('  Validacao do numero do documento (tamanho fora padrao): ' || l_valida_documento);
            
            if l_valida_documento = 1 then
                RETURN TRUE;
            else
                ok := FALSE;
                w_return_status := 'Documento nao informado ou invalido - ' || p_numero_documento;
                adicionar_erro('ERROR', w_return_status);
                RETURN FALSE;
            end if;

        ELSE
            ok              := FALSE;
            w_return_status := 'Documento nao informado ou invalido - ' || p_numero_documento;
            print_log(w_return_status);
            adicionar_erro('ERROR', w_return_status);
            RETURN FALSE;
        END IF;
    END validar_documento;
    
    FUNCTION validar_documento_cpf (p_tipo_documento   VARCHAR2,
                               p_numero_documento VARCHAR2) RETURN BOOLEAN IS
        
        v_cpf        VARCHAR2(11);
        v_digito1    NUMBER;
        v_digito2    NUMBER;
        v_soma       NUMBER;
        v_resto      NUMBER;
    BEGIN
        
        -- Remove caracteres nao numericos
        v_cpf := REGEXP_REPLACE(p_numero_documento, '[^0-9]', '');
    
        -- Verifica se tem 11 digitos ou se e uma sequencia de numeros repetidos
        IF LENGTH(v_cpf) != 11 OR 
           v_cpf IN ('00000000000', '11111111111', '22222222222', '33333333333',
                     '44444444444', '55555555555', '66666666666', '77777777777', 
                     '88888888888', '99999999999') THEN
            
            ok              := FALSE;
            w_return_status := 'Documento nao informado ou invalido - ' || v_cpf;
            adicionar_erro('ERROR', w_return_status);
            RETURN FALSE;
        END IF;
    
        -- Validacao do primeiro digito Verificador
        v_soma := 0;
        FOR i IN 1..9 LOOP
            v_soma := v_soma + TO_NUMBER(SUBSTR(v_cpf, i, 1)) * (11 - i);
        END LOOP;
        
        v_resto := MOD(v_soma, 11);
        IF v_resto < 2 THEN
            v_digito1 := 0;
        ELSE
            v_digito1 := 11 - v_resto;
        END IF;
    
        -- Validacao do segundo digito Verificador
        v_soma := 0;
        FOR i IN 1..10 LOOP
            v_soma := v_soma + TO_NUMBER(SUBSTR(v_cpf, i, 1)) * (12 - i);
        END LOOP;
        
        v_resto := MOD(v_soma, 11);
        IF v_resto < 2 THEN
            v_digito2 := 0;
        ELSE
            v_digito2 := 11 - v_resto;
        END IF;
    
        -- Compara os digitos calculados com os digitos informados
        IF v_digito1 = TO_NUMBER(SUBSTR(v_cpf, 10, 1)) AND 
           v_digito2 = TO_NUMBER(SUBSTR(v_cpf, 11, 1)) THEN
           
           print_log('  Validacao do ' ||p_tipo_documento||' numero do documento: ' || v_cpf);
           RETURN TRUE;
        ELSE
            ok              := FALSE;
            w_return_status := 'Documento nao informado ou invalido - ' || v_cpf;
            adicionar_erro('ERROR', w_return_status);
            RETURN FALSE;
        END IF;
    END validar_documento_cpf;
    -- =========================================================================
    -- RECUPERAR DOCUMENTOS (CPF/CNPJ -> raiz, filial, dv) -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================
    PROCEDURE recuperar_documentos(p_tipo_documento  VARCHAR2,
                                   p_numero_documento VARCHAR2,
                                   p_documento        OUT VARCHAR2,
                                   p_documento_raiz   OUT VARCHAR2,
                                   p_documento_filial OUT VARCHAR2,
                                   p_documento_dv     OUT VARCHAR2) IS
    BEGIN
        IF p_tipo_documento = 'CPF' THEN--1206 'F'
            p_documento         := SUBSTR(p_numero_documento, 1, 9);
            g_documento_inteiro := SUBSTR(p_numero_documento, 1, 11);
            p_documento_raiz    := SUBSTR(p_numero_documento, 1, 9);
            p_documento_filial  := '0000';
            p_documento_dv      := SUBSTR(p_numero_documento, 10, 2);
            g_global_attribute9 := '1';
        ELSE
            p_documento         := SUBSTR(p_numero_documento, 1, 8);
            g_documento_inteiro := SUBSTR(p_numero_documento, 1, 14);
            p_documento_raiz    := LPAD(SUBSTR(p_numero_documento, 1, 8), 9, '0');
            p_documento_filial  := SUBSTR(p_numero_documento, 9, 4);
            p_documento_dv      := SUBSTR(p_numero_documento, 13, 2);
            g_global_attribute9 := '2';
        END IF;
                
    END recuperar_documentos;

    -- =========================================================================
    -- RECUPERAR PERFIL DO CLIENTE -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================
    PROCEDURE recuperar_profile(p_customer_profile_rec IN OUT hz_customer_profile_v2pub.customer_profile_rec_type) IS
        l_classe_cliente VARCHAR2(100) := 'PERFIL ZZZ';
    BEGIN
        BEGIN
            SELECT profile_class_id,
                   global_attribute_category,
                   global_attribute1,
                   global_attribute2,
                   global_attribute3,
                   global_attribute4,
                   global_attribute5,
                   global_attribute6,
                   global_attribute7,
                   global_attribute8,
                   global_attribute9,
                   'N'
              INTO p_customer_profile_rec.profile_class_id,
                   p_customer_profile_rec.global_attribute_category,
                   p_customer_profile_rec.global_attribute1,
                   p_customer_profile_rec.global_attribute2,
                   p_customer_profile_rec.global_attribute3,
                   p_customer_profile_rec.global_attribute4,
                   p_customer_profile_rec.global_attribute5,
                   p_customer_profile_rec.global_attribute6,
                   p_customer_profile_rec.global_attribute7,
                   p_customer_profile_rec.global_attribute8,
                   p_customer_profile_rec.global_attribute9,
                   p_customer_profile_rec.credit_hold
              FROM hz_cust_profile_classes
             WHERE status = 'A'
               AND name   = l_classe_cliente;
        EXCEPTION
            WHEN OTHERS THEN
                ok := FALSE;
                print_log('Erro ao buscar Classe do Contribuinte:' || SQLERRM);
                adicionar_erro('ERROR', 'Erro ao buscar Classe do Contribuinte:' || SQLERRM);
        END;

        BEGIN
            SELECT term_id
              INTO p_customer_profile_rec.standard_terms
              FROM ra_terms
             WHERE end_date_active IS NULL
               AND name = 'A VISTA';
        EXCEPTION
            WHEN OTHERS THEN
                ok := FALSE;
                adicionar_erro('ERROR', 'Erro ao buscar Condicao de Pagamento:' || SQLERRM);
        END;
    END recuperar_profile;

    -- =========================================================================
    -- VALIDAR / LOCALIZAR FORNECEDOR EXISTENTE -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- Retorna: 1=encontrado como cliente AR, 2=encontrado como fornecedor AP,
    --          3=party_id encontrado sem site, 0=nao encontrado
    -- =========================================================================
    FUNCTION validar_fornecedor RETURN NUMBER IS
        l_result NUMBER;
    BEGIN
        -- 1a validacao: ja existe como cliente AR com site
        BEGIN
             --08092026 substituindo a view xxarco_ar_customers_v pela CLL_F255_AR_CUSTOMERS_V  
             SELECT DISTINCT party_id, party_site_id, location_id, 1
              INTO w_party_id, w_party_site_id, w_location_id, l_result
              FROM CLL_F255_AR_CUSTOMERS_V v
             WHERE document_number = g_documento_inteiro
               AND org_id IN (SELECT TO_NUMBER(flv.lookup_code)
                                FROM fnd_lookup_values flv
                               WHERE flv.lookup_type  = 'XXARCO_ORG_RCPT_METHOD'
                                 AND flv.enabled_flag = 'Y'
                                 AND flv.language     = 'PTB')
               AND rownum = 1;
             
             print_log('1-  Vendor encontrado na CLL_F255_AR_CUSTOMERS_V - ' || g_documento_inteiro);
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                -- 2a validacao: existe como fornecedor AP com site na org desejada
                BEGIN
                    SELECT party_id, party_site_id, location_id, 2
                      INTO w_party_id, w_party_site_id, w_location_id, l_result
                      FROM xxarco_ap_suppliers_v
                     WHERE document_number = g_documento_inteiro
                       AND org_id IN (SELECT TO_NUMBER(flv.lookup_code)
                                        FROM fnd_lookup_values flv
                                       WHERE flv.lookup_type  = 'XXARCO_ORG_RCPT_METHOD'
                                         AND flv.enabled_flag = 'Y'
                                         AND flv.language     = 'PTB')
                       AND ROWNUM          = 1;
                    print_log('2-  Vendor encontrado na xxarco_ap_suppliers_v (org lookup) - ' || g_documento_inteiro);
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        -- 3a validacao: fornecedor AP sem org especifica
                        BEGIN
                            SELECT party_id, party_site_id, location_id, 2
                              INTO w_party_id, w_party_site_id, w_location_id, l_result
                              FROM xxarco_ap_suppliers_v
                             WHERE document_number  = g_documento_inteiro
                               AND party_site_id   IS NOT NULL
                               AND ROWNUM           = 1;
                            print_log('3-  Vendor encontrado na xxarco_ap_suppliers_v - ' || g_documento_inteiro);
                        EXCEPTION
                            WHEN NO_DATA_FOUND THEN
                                -- 4a validacao: party_id sem site
                                BEGIN
                                    SELECT DISTINCT party_id, vendor_id, 3
                                      INTO w_party_id, w_vendor_id, l_result
                                      FROM xxarco_ap_suppliers_v
                                     WHERE raiz_doc = g_documento
                                       AND ROWNUM   = 1;
                                       
                                EXCEPTION
                                    WHEN NO_DATA_FOUND THEN
                                        -- 5a validacao: pelo vendor_code
                                        BEGIN
                                            SELECT DISTINCT party_id, vendor_id, 3
                                              INTO w_party_id, w_vendor_id, l_result
                                              FROM xxarco_ap_suppliers_v
                                             WHERE vendor_code = g_documento
                                               AND ROWNUM      = 1;
                                            print_log('5-  Vendor encontrado pela 5a validacao - ' || g_documento);
                                        EXCEPTION
                                            WHEN NO_DATA_FOUND THEN
                                                print_log('Nenhuma das 5 validacoes encontrou registros - ' || g_documento_inteiro);
                                            WHEN OTHERS THEN
                                                adicionar_erro('ERROR', '5a validacao: ' || SQLERRM, FALSE);
                                                print_log('5a validacao - ' || SQLERRM);
                                        END;
                                    WHEN OTHERS THEN
                                        adicionar_erro('ERROR', '4a validacao: ' || SQLERRM, FALSE);
                                        print_log('4a validacao - ' || SQLERRM);
                                END;
                            WHEN OTHERS THEN
                                adicionar_erro('ERROR', '3a validacao: ' || SQLERRM, FALSE);
                                print_log('3a validacao - ' || SQLERRM);
                        END;
                    WHEN OTHERS THEN
                        adicionar_erro('ERROR', '2a validacao: ' || SQLERRM, FALSE);
                        print_log('2a validacao - ' || SQLERRM);
                END;
            WHEN OTHERS THEN
                adicionar_erro('ERROR', '1a validacao: ' || SQLERRM, FALSE);
                print_log('1a validacao - ' || SQLERRM);
        END;

        RETURN NVL(l_result, 0);
    END validar_fornecedor;

    -- =========================================================================
    -- VERIFICAR SE JA EXISTE FORNECEDOR PARA O PARTY_ID -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================
    FUNCTION existe_fornecedor(p_party_id  NUMBER,
                               p_vendor_id OUT NUMBER) RETURN VARCHAR2 IS
    BEGIN
        -- 1. Tenta achar o vendor pelo party_id
        BEGIN
            SELECT DISTINCT vendor_id
              INTO p_vendor_id
              FROM apps.ap_suppliers
             WHERE party_id = p_party_id
               AND ROWNUM   = 1;
        EXCEPTION
            WHEN OTHERS THEN
                print_log('  AVISO [existe_fornecedor]: Nao encontrou pelo party_id ' || p_party_id || ': ' || SQLERRM);
                p_vendor_id := NULL;
        END;

        -- 2. Se nao achou, tenta achar pelo CNPJ raiz (base suja com varios parties pro mesmo CNPJ)
        IF p_vendor_id IS NULL THEN
            BEGIN
                SELECT DISTINCT vendor_id
                  INTO p_vendor_id
                  FROM xxarco_ap_suppliers_v
                 WHERE raiz_doc = g_documento
                   AND ROWNUM   = 1;
            EXCEPTION
                WHEN OTHERS THEN
                    print_log('  AVISO [existe_fornecedor]: Nao encontrou pelo CNPJ ' || g_documento || ': ' || SQLERRM);
                    p_vendor_id := NULL;
            END;
        END IF;

        IF p_vendor_id IS NOT NULL THEN
            print_log('##### Fornecedor ja cadastrado. party_id base: ' || p_party_id || ' vendor_id encontrado: ' || p_vendor_id);
            RETURN 'S';
        ELSE
            RETURN 'N';
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN 'N';
        WHEN OTHERS THEN
            print_log('Erro em existe_fornecedor, p_party_id: ' || p_party_id || ' - ' || SQLERRM);
            RETURN 'E';
    END existe_fornecedor;

    -- =========================================================================
    -- VERIFICAR MODIFICACAO NO SITE DO CLIENTE -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================
    FUNCTION verif_mod_cliente_site(p_dados              rec_dados_cliente,
        p_inscricao_estadual OUT VARCHAR2,
        p_org_id             NUMBER) RETURN VARCHAR2 IS
        l_lagradouro         VARCHAR2(100);
        l_numero             VARCHAR2(100);
        l_bairro             VARCHAR2(100);
        l_complemento        VARCHAR2(100);
        l_cidade             VARCHAR2(100);
        l_estado             VARCHAR2(100);
        l_cep                VARCHAR2(100);
        l_global_attribute6  VARCHAR2(100);
        l_global_attribute7  VARCHAR2(100);
        l_global_attribute10 VARCHAR2(100);
        l_global_attribute13 VARCHAR2(100);
        l_global_attribute8  VARCHAR2(100);
        l_bill_encontrado    BOOLEAN;

        FUNCTION verif_exist_bill_site_use_id RETURN BOOLEAN IS
            l_bill_to_site_use_id NUMBER;
        BEGIN
            SELECT hcsu.bill_to_site_use_id
              INTO l_bill_to_site_use_id
              FROM hz_cust_site_uses_all hcsu
             WHERE cust_acct_site_id = w_cust_acct_site_id
               AND site_use_id       = w_site_use_id
               AND site_use_code     = 'SHIP_TO';

            RETURN (l_bill_to_site_use_id IS NOT NULL);
        EXCEPTION
            WHEN OTHERS THEN
                RETURN TRUE;
        END verif_exist_bill_site_use_id;

    BEGIN
        print_log('  Cliente existente, verificando site, party_site_id: ' || w_party_site_id);
        --adicionar_erro('INFO', 'Cliente existente, party_site_id:' || w_party_site_id, FALSE); 03072026

        BEGIN
            --08092026 substituindo a view xxarco_ar_customers_v pela CLL_F255_AR_CUSTOMERS_V  
            SELECT cfac.address1, cfac.address2, cfac.address3, cfac.address4,
                   cfac.city, cfac.state, cfac.postal_code,
                   cfac.global_attribute6,
                   cfac.global_attribute7,
                   cfac.GLOBAL_ATTRIBUTE13,
                   cfac.GLOBAL_ATTRIBUTE8,
                   cfac.customer_id
              INTO l_lagradouro, l_numero, l_bairro, l_complemento,
                   l_cidade, l_estado, l_cep,
                   l_global_attribute6,
                   l_global_attribute7,
                   l_global_attribute13,
                   l_global_attribute8,
                   w_cust_account_id
              FROM CLL_F255_AR_CUSTOMERS_V cfac
             WHERE org_id        = p_org_id
               AND party_id      = w_party_id
               AND party_site_id = w_party_site_id
               AND site_use_code IN ('SHIP_TO')
                 AND ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                BEGIN
                    SELECT account_number, cust_account_id
                      INTO w_account_number, w_cust_account_id
                      FROM hz_cust_accounts
                     WHERE account_name   = p_dados.nome_cliente
                       AND account_number = p_dados.numero_documento;

                    w_cust_acct_site_id := NULL; -- garante NULL antes de buscar
                    SELECT cust_acct_site_id
                      INTO w_cust_acct_site_id
                      FROM hz_cust_acct_sites hcas
                     WHERE cust_account_id = w_cust_account_id
                       AND party_site_id   = w_party_site_id
                       AND org_id          = p_org_id; -- filtro correto por org
                EXCEPTION
                    WHEN OTHERS THEN
                        w_cust_acct_site_id := NULL; -- garante NULL se nao encontrar
                        print_log('  Aviso: Customer site nao encontrado - ' || SQLERRM);
                END;
                RETURN 'NAO_EXISTE_SHIP';
            WHEN OTHERS THEN
                print_log('  ERRO: validar customer site SHIP_TO - ' || SQLERRM);
        END;

        BEGIN
            SELECT hcsu.cust_acct_site_id, hcsu.site_use_id
              INTO w_cust_acct_site_id, w_site_use_id
              FROM hz_cust_site_uses_all hcsu,
                   hz_cust_acct_sites    hcas
             WHERE hcas.cust_account_id    = w_cust_account_id
               AND hcsu.cust_acct_site_id  = hcas.cust_acct_site_id
               AND hcsu.site_use_code     IN ('SHIP_TO')
               AND hcas.party_site_id      = w_party_site_id;
            l_bill_encontrado := verif_exist_bill_site_use_id;
        EXCEPTION
            WHEN OTHERS THEN
                l_bill_encontrado := TRUE;
        END;

        p_inscricao_estadual := UPPER(TRANSLATE(p_dados.inscricao_estadual, '.-/', '   '));

        IF (l_lagradouro           != p_dados.logradouro)                                   OR
           (l_numero               != p_dados.numero)                                        OR
           (l_bairro               != p_dados.bairro)                                        OR
           (NVL(l_complemento, '') != NVL(p_dados.complemento, ''))                          OR           
           (l_cidade               != p_dados.cidade)                                        OR
           (l_estado               != p_dados.unidadefederativa)                             OR
           (l_cep                  != LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0'))    OR
           (l_global_attribute6    != p_inscricao_estadual)                                  OR
           (NVL(l_global_attribute8, 'x')  != g_tipo_contribuite)                            OR
           (NVL(l_global_attribute13, 'x') != g_indicador_ie_dest)                           OR
           l_bill_encontrado = FALSE
        THEN
            RETURN 'ATUALIZAR';
        ELSE
            RETURN 'SITE_EXISTE';
        END IF;
    END verif_mod_cliente_site;

    -- =========================================================================
    -- VERIFICAR MODIFICACAO NO SITE DO FORNECEDOR -> EXTRAIDO DA XXPSD_AP_PCK_INT_CLIENTE
    -- =========================================================================
    FUNCTION verif_mod_forn_site(p_documento_raiz   VARCHAR2,
                                 p_documento_filial VARCHAR2,
                                 p_documento_dv     VARCHAR2,
                                 p_dados            rec_dados_cliente,
                                 p_inscricao_estadual VARCHAR2,
                                 p_vendor_site      OUT NUMBER,
                                 p_location_id      OUT NUMBER,
                                 p_org_id           NUMBER) RETURN VARCHAR2 IS
        l_lagradouro         VARCHAR2(100);
        l_numero             VARCHAR2(100);
        l_bairro             VARCHAR2(100);
        l_complemento        VARCHAR2(100);
        l_cidade             VARCHAR2(100);
        l_estado             VARCHAR2(100);
        l_cep                VARCHAR2(100);
        l_global_attribute13 VARCHAR2(100);
        l_enabled            po_vendors.enabled_flag%TYPE;
        l_inactive_date      po_vendor_sites_all.inactive_date%TYPE; -- data inativacao do SITE (pvsa), nao do vendor header
        l_vendor_name        po_vendors.vendor_name%TYPE;
        l_vendor_name_alt    po_vendors.vendor_name_alt%TYPE;
    BEGIN
        BEGIN
            SELECT pvsa.address_line1, pvsa.address_line2, pvsa.address_line3, pvsa.address_line4,
                   pvsa.city, pvsa.state, pvsa.zip, pvsa.global_attribute13,
                   pvsa.vendor_site_id, pvsa.inactive_date, pva.enabled_flag,
                   pvsa.location_id, pva.vendor_id,
                   pva.vendor_name, pva.vendor_name_alt
              INTO l_lagradouro, l_numero, l_bairro, l_complemento,
                   l_cidade, l_estado, l_cep, l_global_attribute13,
                   p_vendor_site, l_inactive_date, l_enabled,
                   p_location_id, w_vendor_id,
                   l_vendor_name, l_vendor_name_alt
              FROM apps.po_vendor_sites_all pvsa,
                   apps.po_vendors          pva
             WHERE ((pvsa.global_attribute10 = p_documento_raiz
                     AND pvsa.global_attribute11 = p_documento_filial
                     AND pvsa.global_attribute12 = p_documento_dv)
                    OR pvsa.vendor_site_code = w_vendor_site_code)
               AND ROWNUM      = 1
               AND pva.vendor_id = pvsa.vendor_id
               AND pvsa.org_id   = p_org_id
               AND pvsa.vendor_id = w_vendor_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                print_log('  AVISO: Site do fornecedor nao encontrado, vendor_site_code: ' || w_vendor_site_code);
            WHEN OTHERS THEN
                print_log('  ERRO: verificar site fornecedor - ' || SQLERRM);
                p_vendor_site := 0;
        END;

        IF NVL(p_vendor_site, 0) != 0 THEN
            IF (l_lagradouro  != p_dados.logradouro)                                           OR
               (l_numero      != p_dados.numero)                                               OR
               (l_bairro      != p_dados.bairro)                                               OR
               (NVL(l_complemento, '') != NVL(p_dados.complemento, ''))                        OR               
               (l_cidade      != p_dados.cidade)                                               OR
               (l_vendor_name != p_dados.nome_cliente)                                         OR
               (l_vendor_name_alt != p_dados.nome_fantasia)                                    OR
               (l_estado      != p_dados.unidadefederativa)                                    OR
               (l_cep         != LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0'))            OR
               (l_global_attribute13 != p_inscricao_estadual)                                  OR
               -- Verifica se o SITE esta inativo (pvsa.inactive_date <= hoje)
               -- CORRECAO: antes usava pva.end_date_active (header do vendor) que nunca detectava site inativo
               (NVL(l_inactive_date, TRUNC(SYSDATE) + 1) <= TRUNC(SYSDATE))                  OR
               (l_enabled <> 'Y')
            THEN
                RETURN 'ATUALIZAR';
            ELSE
                RETURN 'SITE_EXISTE';
            END IF;
        ELSE
            RETURN 'SITE_INEXISTENTE';
        END IF;
    END verif_mod_forn_site;

    -- =========================================================================
    -- CRIAR / ATUALIZAR CONTATOS (EMAIL e TELEFONE)
    -- =========================================================================
    PROCEDURE criar_atualizar_contato_tel(p_party_site_id NUMBER,
                                          p_dados         rec_dados_cliente) IS
        lv_return_status        VARCHAR2(500);
        lv_msg_data             VARCHAR2(500);
        lv_api_message          VARCHAR2(4000);
        lv_msg_index_out        NUMBER;
        lv_contact_point_id     NUMBER;
        lv_contact_point_rec    hz_contact_point_v2pub.contact_point_rec_type;
        lv_phone_rec            hz_contact_point_v2pub.phone_rec_type;
        lv_email_rec            hz_contact_point_v2pub.email_rec_type;
        x_edi_rec               hz_contact_point_v2pub.edi_rec_type;
        x_web_rec               hz_contact_point_v2pub.web_rec_type;
        x_telex_rec             hz_contact_point_v2pub.telex_rec_type;
        l_object_version_number hz_contact_points.object_version_number%TYPE;
        l_existe                BOOLEAN DEFAULT FALSE;
    BEGIN
        -- Se Telefone eh nulo nada a fazer
        IF p_dados.telefone IS NULL THEN
            RETURN;
        END IF;

        FOR r1 IN (SELECT *
                     FROM hz_contact_points
                    WHERE owner_table_name = 'HZ_PARTY_SITES'
                      AND owner_table_id   = p_party_site_id
                      AND primary_flag     = 'Y'
                      AND status           = 'A'
                      AND contact_point_type IN ('PHONE'))
        LOOP
            l_existe := TRUE;

            SELECT object_version_number
              INTO l_object_version_number
              FROM hz_contact_points
             WHERE contact_point_id = r1.contact_point_id;

            hz_contact_point_v2pub.get_contact_point_rec(
                p_contact_point_id => r1.contact_point_id,
                x_contact_point_rec => lv_contact_point_rec,
                x_edi_rec           => x_edi_rec,
                x_email_rec         => lv_email_rec,
                x_phone_rec         => lv_phone_rec,
                x_telex_rec         => x_telex_rec,
                x_web_rec           => x_web_rec,
                x_return_status     => w_return_status,
                x_msg_count         => w_msg_count,
                x_msg_data          => w_msg_data);

            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count, 'GET_CONTACT_POINT');
                ok := FALSE;
            END IF;

            lv_phone_rec.phone_number     := p_dados.telefone;
            lv_phone_rec.raw_phone_number := NULL;

            hz_contact_point_v2pub.update_phone_contact_point(
                p_init_msg_list         => fnd_api.g_false,
                p_contact_point_rec     => lv_contact_point_rec,
                p_phone_rec             => lv_phone_rec,
                p_object_version_number => l_object_version_number,
                x_return_status         => w_return_status,
                x_msg_count             => w_msg_count,
                x_msg_data              => w_msg_data);
                
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count, 'UPDATE_PHONE_CONTACT');
                ok := FALSE;
            END IF;
        END LOOP;

        IF NOT l_existe THEN
            lv_contact_point_rec.created_by_module  := g_created_by_module;
            lv_contact_point_rec.contact_point_type := 'PHONE';
            lv_contact_point_rec.status             := 'A';
            lv_contact_point_rec.owner_table_name   := 'HZ_PARTY_SITES';
            lv_contact_point_rec.primary_flag       := 'Y';
            lv_contact_point_rec.owner_table_id     := p_party_site_id;
            lv_phone_rec.phone_number               := p_dados.telefone;
            lv_phone_rec.raw_phone_number           := NULL;
            lv_phone_rec.phone_line_type            := 'GEN';

            hz_contact_point_v2pub.create_phone_contact_point(
                p_init_msg_list     => fnd_api.g_false,
                p_contact_point_rec => lv_contact_point_rec,
                p_phone_rec         => lv_phone_rec,
                x_contact_point_id  => lv_contact_point_id,
                x_return_status     => w_return_status,
                x_msg_count         => w_msg_count,
                x_msg_data          => w_msg_data);
                
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count, 'CREATE_PHONE_CONTACT');
                ok := FALSE;
            END IF;
        END IF;
    END criar_atualizar_contato_tel;

    -- -------------------------------------------------------------------------
    PROCEDURE criar_atualizar_contato(p_party_site_id NUMBER,
                                      p_dados         rec_dados_cliente) IS
        lv_return_status    VARCHAR2(500);
        lv_msg_count        NUMBER;
        lv_msg_data         VARCHAR2(500);
        lv_api_message      VARCHAR2(4000);
        lv_msg_index_out    NUMBER;
        lv_contact_point_id NUMBER;
        l_email             VARCHAR2(255);
        l_existe            BOOLEAN DEFAULT FALSE;
        TYPE rec_purpose_type IS VARRAY(2) OF VARCHAR2(30);
        lv_contact_point_rec    hz_contact_point_v2pub.contact_point_rec_type;
        lv_phone_rec            hz_contact_point_v2pub.phone_rec_type;
        lv_email_rec            hz_contact_point_v2pub.email_rec_type;
        x_edi_rec               hz_contact_point_v2pub.edi_rec_type;
        x_web_rec               hz_contact_point_v2pub.web_rec_type;
        x_telex_rec             hz_contact_point_v2pub.telex_rec_type;
        l_object_version_number hz_contact_points.object_version_number%TYPE;
        l_tab_purpose           rec_purpose_type := rec_purpose_type('BOLETO', 'NFE');
    BEGIN
        FOR r1 IN (SELECT *
                     FROM hz_contact_points
                    WHERE owner_table_name       = 'HZ_PARTY_SITES'
                      AND owner_table_id         = p_party_site_id
                      AND contact_point_purpose IN ('BOLETO', 'NFE')
                      AND contact_point_type     = 'EMAIL')
        LOOP
            l_existe := TRUE;

            SELECT object_version_number
              INTO l_object_version_number
              FROM hz_contact_points
             WHERE contact_point_id = r1.contact_point_id;

            hz_contact_point_v2pub.get_contact_point_rec(
                p_contact_point_id  => r1.contact_point_id,
                x_contact_point_rec => lv_contact_point_rec,
                x_edi_rec           => x_edi_rec,
                x_email_rec         => lv_email_rec,
                x_phone_rec         => lv_phone_rec,
                x_telex_rec         => x_telex_rec,
                x_web_rec           => x_web_rec,
                x_return_status     => w_return_status,
                x_msg_count         => w_msg_count,
                x_msg_data          => w_msg_data);

            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count, 'GET_CONTACT_POINT');
                ok := FALSE;
            END IF;

            l_email := NVL(p_dados.email, p_dados.emailxml);

            lv_email_rec.email_format               := 'MAILTEXT';
            lv_email_rec.email_address              := l_email;

            hz_contact_point_v2pub.update_contact_point(
                p_init_msg_list         => fnd_api.g_false,
                p_contact_point_rec     => lv_contact_point_rec,
                p_email_rec             => lv_email_rec,
                p_phone_rec             => lv_phone_rec,
                p_object_version_number => l_object_version_number,
                x_return_status         => w_return_status,
                x_msg_count             => w_msg_count,
                x_msg_data              => w_msg_data);

            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count, 'UPDATE_CONTACT_POINT');
                ok := FALSE;
            END IF;

            print_log('  Contato ' || r1.contact_point_purpose || ' atualizado.');
        END LOOP;

        IF NOT l_existe THEN
            FOR i IN 1 .. l_tab_purpose.COUNT LOOP
                l_email := NVL(p_dados.email, p_dados.emailxml);

                lv_contact_point_rec.contact_point_type    := 'EMAIL';
                lv_contact_point_rec.contact_point_purpose := l_tab_purpose(i);
                lv_contact_point_rec.created_by_module     := g_created_by_module;
                lv_contact_point_rec.status                := 'A';
                lv_contact_point_rec.owner_table_name      := 'HZ_PARTY_SITES';
                lv_contact_point_rec.owner_table_id        := p_party_site_id;
                lv_contact_point_rec.primary_flag          := 'N';
                lv_email_rec.email_format                  := 'MAILTEXT';
                lv_email_rec.email_address                 := l_email;

                hz_contact_point_v2pub.create_contact_point(
                    p_init_msg_list     => fnd_api.g_true,
                    p_contact_point_rec => lv_contact_point_rec,
                    p_email_rec         => lv_email_rec,
                    p_phone_rec         => lv_phone_rec,
                    x_contact_point_id  => lv_contact_point_id,
                    x_return_status     => lv_return_status,
                    x_msg_count         => lv_msg_count,
                    x_msg_data          => lv_msg_data);

                IF lv_return_status <> fnd_api.g_ret_sts_success THEN
                    extrair_mensagens_api(lv_msg_count, 'CREATE_CONTACT_POINT');
                    ok := FALSE;
                END IF;

                print_log('  Contato ' || l_tab_purpose(i) || ' cadastrado, id: ' || lv_contact_point_id);
            END LOOP;
        END IF;

        -- Telefone
        criar_atualizar_contato_tel(p_party_site_id, p_dados);
    END criar_atualizar_contato;

    -- =========================================================================
    -- CRIAR / ATUALIZAR LOCALIZACAO (HZ_LOCATIONS)
    -- =========================================================================
    PROCEDURE criar_localizacao(p_dados       rec_dados_cliente,
                                p_location_id OUT NUMBER) IS
        l_location_rec hz_location_v2pub.location_rec_type;
    BEGIN
        l_location_rec.address1          := p_dados.logradouro;
        l_location_rec.address2          := p_dados.numero;
        l_location_rec.address3          := p_dados.bairro;
        l_location_rec.address4          := NVL(p_dados.complemento, FND_API.G_MISS_CHAR);
        l_location_rec.postal_code       := LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0');
        l_location_rec.country           := g_country;
        l_location_rec.city              := p_dados.cidade;
        l_location_rec.state             := p_dados.unidadefederativa;
        l_location_rec.created_by_module := g_created_by_module;

        print_log('Chamando HZ_LOCATION_V2PUB.CREATE_LOCATION');
        hz_location_v2pub.create_location(
            p_init_msg_list => fnd_api.g_true,
            p_location_rec  => l_location_rec,
            x_location_id   => p_location_id,
            x_return_status => w_return_status,
            x_msg_count     => w_msg_count,
            x_msg_data      => w_msg_data);    
        
        IF w_return_status <> fnd_api.g_ret_sts_success THEN
            print_log('##### create_location status: ' || w_return_status);  
            print_log('  Falha ao criar Location: ' || w_msg_data);
            extrair_mensagens_api(w_msg_count);
            ok := FALSE;
            
        END IF;
    END criar_localizacao;

    -- -------------------------------------------------------------------------
    PROCEDURE atualizar_localizacao(p_dados rec_dados_cliente) IS
        l_location_rec          hz_location_v2pub.location_rec_type;
        p_object_version_number NUMBER;
    BEGIN
        l_location_rec.location_id := w_location_id;
        l_location_rec.address1    := p_dados.logradouro;
        l_location_rec.address2    := p_dados.numero;
        l_location_rec.address3    := p_dados.bairro;
        l_location_rec.address4    := NVL(p_dados.complemento, FND_API.G_MISS_CHAR);
        l_location_rec.postal_code := LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0');
        l_location_rec.country     := g_country;
        l_location_rec.city        := g_cidade;
        l_location_rec.state       := g_estado;

        BEGIN
            SELECT object_version_number
              INTO p_object_version_number
              FROM hz_locations
             WHERE location_id = w_location_id;
        EXCEPTION
            WHEN OTHERS THEN
                p_object_version_number := 1;
        END;

        print_log('Chamando HZ_LOCATION_V2PUB.UPDATE_LOCATION. location_id: ' || w_location_id);
        hz_location_v2pub.update_location(
            p_init_msg_list         => fnd_api.g_true,
            p_location_rec          => l_location_rec,
            p_object_version_number => p_object_version_number,
            x_return_status         => w_return_status,
            x_msg_count             => w_msg_count,
            x_msg_data              => w_msg_data);

        IF w_return_status <> fnd_api.g_ret_sts_success THEN
            print_log('##### update_location status: ' || w_return_status); 
            print_log('  Falha ao atualizar Localizacao: ' || w_msg_data);
            extrair_mensagens_api(w_msg_count);
            ok := FALSE;
            
        END IF;
    END atualizar_localizacao;

    -- =========================================================================
    -- CRIAR PARTY SITE (HZ_PARTY_SITES)
    -- =========================================================================
    PROCEDURE criar_party_site IS
        p_party_site_rec hz_party_site_v2pub.party_site_rec_type;
    BEGIN
        p_party_site_rec.party_id                 := w_party_id;
        p_party_site_rec.location_id              := w_location_id;
        p_party_site_rec.identifying_address_flag := 'Y';
        p_party_site_rec.created_by_module        := g_created_by_module;

        print_log('Chamando HZ_PARTY_SITE_V2PUB.CREATE_PARTY_SITE');
        hz_party_site_v2pub.create_party_site(
            p_init_msg_list     => fnd_api.g_true,
            p_party_site_rec    => p_party_site_rec,
            x_party_site_id     => w_party_site_id,
            x_party_site_number => w_party_number,
            x_return_status     => w_return_status,
            x_msg_count         => w_msg_count,
            x_msg_data          => w_msg_data);

        IF w_return_status = fnd_api.g_ret_sts_success THEN
            print_log('##### create_party_site status: ' || w_return_status);
            print_log('  Falha ao criar Party Site: ' || w_msg_data);
            extrair_mensagens_api(w_msg_count);
            ok := FALSE;
            
        END IF;
    END criar_party_site;

    -- =========================================================================
    -- ATUALIZAR PARTY (HZ_PARTIES) - nome do cadastro
    -- =========================================================================
    PROCEDURE atualizar_party(p_dados rec_dados_cliente) IS
        p_object_version_number NUMBER;
        p_profile_id            NUMBER;
        l_party_rec             hz_party_v2pub.organization_rec_type;
    BEGIN
        l_party_rec.party_rec.party_id := w_party_id;
        l_party_rec.organization_name  := p_dados.nome_cliente;

        BEGIN
            SELECT object_version_number
              INTO p_object_version_number
              FROM hz_parties
             WHERE party_id = w_party_id;
        EXCEPTION
            WHEN OTHERS THEN
                p_object_version_number := 1;
        END;

        print_log('Chamando HZ_PARTY_V2PUB.UPDATE_ORGANIZATION, party_id: ' || w_party_id);
        hz_party_v2pub.update_organization(
            p_init_msg_list               => fnd_api.g_true,
            p_organization_rec            => l_party_rec,
            p_party_object_version_number => p_object_version_number,
            x_profile_id                  => p_profile_id,
            x_return_status               => w_return_status,
            x_msg_count                   => w_msg_count,
            x_msg_data                    => w_msg_data);

        IF w_return_status <> fnd_api.g_ret_sts_success THEN
            print_log('##### update_organization status: ' || w_return_status);
            print_log('  Falha ao atualizar Party: ' || w_msg_data);
            
        END IF;
    END atualizar_party;

    -- =========================================================================
    -- FORNECEDOR AP: CRIAR
    -- =========================================================================
    PROCEDURE criar_fornecedor(p_dados   rec_dados_cliente,
                               l_retorno OUT VARCHAR2) IS
        l_vendor_rec    ap_vendor_pub_pkg.r_vendor_rec_type;
        l_msg           VARCHAR2(2000);
        l_verificar     NUMBER := 0;
        l_verif_cliente NUMBER := 0;
    BEGIN
        BEGIN
            SELECT COUNT(*)
              INTO l_verificar
              FROM ap_suppliers
             WHERE UPPER(vendor_name) LIKE UPPER(p_dados.nome_cliente)
             AND segment1 <> g_documento_raiz; --31082026 Garante que barra apenas se for outro CNPJ
        EXCEPTION
            WHEN OTHERS THEN l_verificar := 0;
        END;

        BEGIN
            SELECT COUNT(*)
              INTO l_verif_cliente
              FROM hz_parties
             WHERE UPPER(party_name) = UPPER(p_dados.nome_cliente);
        EXCEPTION
            WHEN OTHERS THEN l_verificar := 0;
        END;

        -- Trata homonimos adicionando ponto ao nome
        IF l_verificar > 0 OR l_verif_cliente > 0 THEN
            l_vendor_rec.vendor_name     := p_dados.nome_cliente || '.';
            l_vendor_rec.vendor_name_alt := p_dados.nome_fantasia || '.';
        ELSE
            l_vendor_rec.vendor_name     := p_dados.nome_cliente;
            l_vendor_rec.vendor_name_alt := p_dados.nome_fantasia;
        END IF;
        
        l_retorno                               := 's';
        l_vendor_rec.party_id                   := w_party_id;
        l_vendor_rec.segment1                   := g_documento;
        l_vendor_rec.vendor_type_lookup_code    := 'VENDOR';
        l_vendor_rec.always_take_disc_flag      := 'Y';
        l_vendor_rec.pay_date_basis_lookup_code := 'DISCOUNT';
        l_vendor_rec.allow_awt_flag             := 'Y';
        l_vendor_rec.global_attribute1          := 'N';
        l_vendor_rec.match_option               := 'R';

        fnd_msg_pub.initialize;
        print_log('Chamando POS_VENDOR_PUB_PKG.CREATE_VENDOR...');            

        SAVEPOINT antes_criar_vendor;   -- ADICIONAR
        
        pos_vendor_pub_pkg.create_vendor(
            p_vendor_rec    => l_vendor_rec,
            x_return_status => w_return_status,
            x_msg_count     => w_msg_count,
            x_msg_data      => w_msg_data,
            x_vendor_id     => w_vendor_id,
            x_party_id      => w_party_id);

print_log('##### create_vendor status: ' || w_return_status);

        print_log('  Vendor Id: ' || w_vendor_id);
        print_log('  Party Id : ' || w_party_id);       
            
        extrair_mensagens_api(w_msg_count);
        
        IF w_return_status <> 'S' THEN
            ROLLBACK TO antes_criar_vendor;
            ok := FALSE;
            l_retorno := 'e';
            print_log('##### ERRO create_vendor: ' || w_msg_data);
            adicionar_erro('ERROR', 'CREATE_VENDOR: ' || w_msg_data);            
            
            IF w_vendor_id IS NOT NULL THEN
				w_return_status := 'INFO: Ja existe um Fornecedor com esses dados cadastrados.';
                l_retorno := 'e';
            END IF;
        END IF;
    END criar_fornecedor;

    -- =========================================================================
    -- FORNECEDOR AP: CRIAR SITE
    -- =========================================================================
    PROCEDURE criar_fornecedor_site(p_dados rec_dados_cliente,
                                    p_org_id NUMBER) IS
        l_pay_date_basis_lookup_code VARCHAR2(50);
        l_natueza_juridica           VARCHAR2(50);
        l_address_style              VARCHAR2(30);
        l_vendor_site_rec            ap_vendor_pub_pkg.r_vendor_site_rec_type;
    BEGIN
        SELECT pay_date_basis_lookup_code
          INTO l_pay_date_basis_lookup_code
          FROM ap_system_parameters_all
         WHERE org_id = p_org_id;

        BEGIN
            SELECT b.business_code
              INTO l_natueza_juridica
              FROM fnd_lookup_values f,
                   cll_f189_business_vendors b
             WHERE f.language     = 'PTB'
               AND f.lookup_type  = 'CLL_F407_LEGAL_NATURE'
               AND f.attribute1   = b.business_code
               AND f.lookup_code  = p_dados.natureza_juridica;
        EXCEPTION
            WHEN OTHERS THEN
                l_natueza_juridica := 'COMERCIAL';
        END;

        l_vendor_site_rec.vendor_site_code           := w_vendor_site_code;
        l_vendor_site_rec.vendor_id                  := w_vendor_id;
        l_vendor_site_rec.phone                      := p_dados.telefone;
        l_vendor_site_rec.address_line1              := p_dados.logradouro;
        l_vendor_site_rec.address_line2              := p_dados.numero;
        l_vendor_site_rec.address_line3              := p_dados.bairro;
        l_vendor_site_rec.address_line4              := NVL(p_dados.complemento, FND_API.G_MISS_CHAR);
        l_vendor_site_rec.zip                        := LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0');
        l_vendor_site_rec.email_address              := p_dados.email;
        l_vendor_site_rec.org_id                     := p_org_id;
        l_vendor_site_rec.country                    := g_country;
        l_vendor_site_rec.address_style              := l_address_style;
        l_vendor_site_rec.city                       := p_dados.cidade;
        l_vendor_site_rec.state                      := p_dados.unidadefederativa;
        l_vendor_site_rec.language                   := 'BRAZILIAN PORTUGUESE';
        l_vendor_site_rec.pay_date_basis_lookup_code := l_pay_date_basis_lookup_code;
        l_vendor_site_rec.country_of_origin_code     := 'BR';
        l_vendor_site_rec.create_debit_memo_flag     := 'N';
        l_vendor_site_rec.purchasing_site_flag       := 'Y';
        l_vendor_site_rec.pay_site_flag              := 'Y';
        l_vendor_site_rec.rfq_only_site_flag         := 'N';
        l_vendor_site_rec.global_attribute_category  := 'JL.BR.APXVDMVD.SITES';
        l_vendor_site_rec.global_attribute1          := 'Y';
        l_vendor_site_rec.global_attribute9          := g_global_attribute9;
        l_vendor_site_rec.global_attribute10         := g_documento_raiz;
        l_vendor_site_rec.global_attribute11         := g_documento_filial;
        l_vendor_site_rec.global_attribute12         := g_documento_dv;
        l_vendor_site_rec.global_attribute13         := REPLACE(REPLACE(UPPER(TRANSLATE(p_dados.inscricao_estadual, '.-/', '   ')), 'ISENTO', ''), 'ISENTA', '');
        l_vendor_site_rec.global_attribute15         := l_natueza_juridica;
        l_vendor_site_rec.global_attribute17         := p_dados.codigosuframa;
        l_vendor_site_rec.party_site_id              := w_party_site_id;
        l_vendor_site_rec.location_id               := w_location_id;

        print_log('Chamando POS_VENDOR_PUB_PKG.CREATE_VENDOR_SITE...');
        pos_vendor_pub_pkg.create_vendor_site(
            p_vendor_site_rec => l_vendor_site_rec,
            x_vendor_site_id  => w_vendor_site_id,
            x_party_site_id   => w_party_site_id,
            x_location_id     => w_location_id,
            x_return_status   => w_return_status,
            x_msg_count       => w_msg_count,
            x_msg_data        => w_msg_data);

        IF w_return_status = fnd_api.g_ret_sts_success THEN
            
            print_log('  Site do fornecedor criado. vendor_site_id: ' || w_vendor_site_id);
            g_fornec_incluir := 'S';
        ELSE
            print_log('##### create_vendor_site status: ' || w_return_status);
            print_log('  Falha ao criar site do fornecedor: ' || w_msg_data);
            extrair_mensagens_api(w_msg_count);
            ok := FALSE;
        END IF;
    END criar_fornecedor_site;

    -- =========================================================================
    -- FORNECEDOR AP: ATUALIZAR SITE
    -- =========================================================================
    PROCEDURE atualizar_fornecedor_site(p_dados rec_dados_cliente,
                                        p_org_id NUMBER) IS
        l_vendor_site_rec ap_vendor_pub_pkg.r_vendor_site_rec_type;
        l_vendor_rec      ap_vendor_pub_pkg.r_vendor_rec_type;
        l_organization_rec hz_party_v2pub.organization_rec_type;
        l_person_rec_type  hz_party_v2pub.person_rec_type;
        l_party_rec        hz_party_v2pub.party_rec_type;
        x_profile_id            NUMBER;
        l_party_id              NUMBER;
        l_object_version_number NUMBER;
        l_party_type            hz_parties.party_type%TYPE;
        l_vendor_desativado     NUMBER;
        l_vendor_name           po_vendors.vendor_name%TYPE;
        l_atualizar_vendor      BOOLEAN DEFAULT FALSE;
    BEGIN
        -- Verificar se vendor esta desativado
        BEGIN
            SELECT COUNT(1)
              INTO l_vendor_desativado
              FROM apps.po_vendors
             WHERE vendor_id = w_vendor_id
               AND TRUNC(end_date_active) < TRUNC(SYSDATE);
        EXCEPTION
            WHEN OTHERS THEN l_vendor_desativado := 0;
        END;

        IF l_vendor_desativado != 0 THEN
            l_atualizar_vendor           := TRUE;
            l_vendor_rec.enabled_flag    := 'Y';
            l_vendor_rec.end_date_active := TO_DATE(SYSDATE + (360 * 10), 'DD/MM/RRRR'); -- Doc ID 2096565.1
        END IF;

        -- Verificar se nome diverge
        BEGIN
            SELECT pv.vendor_name
              INTO l_vendor_name
              FROM apps.po_vendors pv
             WHERE pv.vendor_id = w_vendor_id
               AND pv.vendor_name = p_dados.nome_cliente
               AND NVL(pv.vendor_name_alt, 'x') = NVL(p_dados.nome_fantasia, 'x');
        EXCEPTION
            WHEN OTHERS THEN
                l_vendor_name := NULL;
        END;

        SELECT aps.party_id, hzp.object_version_number, hzp.party_type
          INTO l_party_id, l_object_version_number, l_party_type
          FROM ap_suppliers aps, hz_parties hzp
         WHERE aps.vendor_id = w_vendor_id
           AND aps.party_id = hzp.party_id
           AND ROWNUM       = 1;

        IF l_vendor_name IS NULL THEN
            l_atualizar_vendor           := TRUE;
            l_vendor_rec.vendor_name     := p_dados.nome_cliente;
            l_vendor_rec.vendor_name_alt := p_dados.nome_fantasia;

            IF l_party_type = 'PERSON' THEN
                l_party_rec.party_id               := l_party_id;
                l_party_rec.status                 := 'A';
                l_person_rec_type.person_last_name := p_dados.nome_cliente;
                l_person_rec_type.party_rec        := l_party_rec;
                hz_party_v2pub.update_person(
                    p_init_msg_list               => fnd_api.g_true,
                    p_person_rec                  => l_person_rec_type,
                    p_party_object_version_number => l_object_version_number,
                    x_profile_id                  => x_profile_id,
                    x_return_status               => w_return_status,
                    x_msg_count                   => w_msg_count,
                    x_msg_data                    => w_msg_data);

                
                IF w_return_status <> fnd_api.g_ret_sts_success THEN
                    extrair_mensagens_api(w_msg_count);
                    ok := FALSE;
                    print_log('##### update_person status: ' || w_return_status);
                
                END IF;
            ELSE
                IF p_dados.nome_cliente != NVL(l_organization_rec.organization_name, 'x') THEN
                    
                    l_organization_rec.organization_name          := p_dados.nome_cliente;
                    l_organization_rec.organization_name_phonetic := p_dados.nome_fantasia;
                END IF;
                
                l_organization_rec.party_rec.party_id         := l_party_id;
                
                hz_party_v2pub.update_organization(
                    p_init_msg_list               => fnd_api.g_true,
                    p_organization_rec            => l_organization_rec,
                    p_party_object_version_number => l_object_version_number,
                    x_profile_id                  => x_profile_id,
                    x_return_status               => w_return_status,
                    x_msg_count                   => w_msg_count,
                    x_msg_data                    => w_msg_data);

                IF w_return_status <> fnd_api.g_ret_sts_success THEN
                    extrair_mensagens_api(w_msg_count);
                    ok := FALSE;
                    print_log('##### update_organization status: ' || w_return_status);                                      
                END IF;
            END IF;
        END IF;

        IF l_atualizar_vendor THEN
            l_vendor_rec.vendor_id := w_vendor_id;
            l_vendor_rec.party_id  := l_party_id;
            print_log('Chamando AP_VENDOR_PUB_PKG.UPDATE_VENDOR...');
            ap_vendor_pub_pkg.update_vendor(
                p_api_version      => 1.0,
                p_init_msg_list    => fnd_api.g_true,
                p_commit           => fnd_api.g_false,
                p_validation_level => fnd_api.g_valid_level_full,
                x_return_status    => w_return_status,
                x_msg_count        => w_msg_count,
                x_msg_data         => w_msg_data,
                p_vendor_rec       => l_vendor_rec,
                p_vendor_id        => w_vendor_id);
                
        END IF;

        -- Atualizar site
        l_vendor_site_rec.vendor_id          := w_vendor_id;
        l_vendor_site_rec.party_site_id      := w_party_site_id;
        l_vendor_site_rec.location_id        := w_location_id;
        l_vendor_site_rec.last_update_date   := SYSDATE;
        l_vendor_site_rec.last_updated_by    := -1;
        l_vendor_site_rec.address_line1      := p_dados.logradouro;
        l_vendor_site_rec.address_line2      := p_dados.numero;
        l_vendor_site_rec.address_line3      := p_dados.bairro;
        l_vendor_site_rec.address_line4      := NVL(p_dados.complemento, FND_API.G_MISS_CHAR);
        l_vendor_site_rec.zip                := LPAD(TRANSLATE(p_dados.cep, '.-/', '  '), 8, '0');
        l_vendor_site_rec.org_id             := p_org_id;
        l_vendor_site_rec.country            := p_dados.pais;
        l_vendor_site_rec.city               := p_dados.cidade;
        l_vendor_site_rec.state              := p_dados.unidadefederativa;
        l_vendor_site_rec.global_attribute9  := g_global_attribute9;
        l_vendor_site_rec.global_attribute10 := g_documento_raiz;
        l_vendor_site_rec.global_attribute11 := g_documento_filial;
        l_vendor_site_rec.global_attribute12 := g_documento_dv;
        l_vendor_site_rec.global_attribute13 := g_inscricao_estadual;
        -- Reativar o site caso esteja inativo (inactive_date no passado)
        -- Padrao Oracle AP: definir inactive_date no futuro para garantir reativacao
        l_vendor_site_rec.inactive_date := TRUNC(SYSDATE) + (360 * 10);

        print_log('Chamando AP_VENDOR_PUB_PKG.UPDATE_VENDOR_SITE...');
        ap_vendor_pub_pkg.update_vendor_site(
            p_api_version      => 1.0,
            p_init_msg_list    => fnd_api.g_false,
            p_commit           => fnd_api.g_false,
            p_validation_level => fnd_api.g_valid_level_full,
            x_return_status    => w_return_status,
            x_msg_count        => w_msg_count,
            x_msg_data         => w_msg_data,
            p_vendor_site_rec  => l_vendor_site_rec,
            p_vendor_site_id   => w_vendor_site_id);



        IF w_return_status <> fnd_api.g_ret_sts_success THEN
            print_log('##### update_vendor_site status: ' || w_return_status);
			print_log('  Falha ao atualizar vendor site: ' || w_msg_data);			
            			            
        END IF;
    END atualizar_fornecedor_site;
    
    -- =========================================================================
    -- ATUALIZAR CONTA AR (CLASSIFICAO, TIPO E LIMITES)
    -- =========================================================================
    PROCEDURE atualizar_classificacao_limites(p_cust_account_id NUMBER,
                                              p_dados           rec_dados_cliente) IS
        l_cust_account_rec   hz_cust_account_v2pub.cust_account_rec_type;
        l_profile_amt_rec    hz_customer_profile_v2pub.cust_profile_amt_rec_type;
        
        l_ovn_account        NUMBER;
        l_customer_class     VARCHAR2(30);
        l_customer_type      VARCHAR2(30);
        l_sales_channel_code VARCHAR2(30);
        l_razao_social       VARCHAR2(200);
        l_attribute8         VARCHAR2(50);
        
        l_profile_id         NUMBER;
        
        l_amt_id             NUMBER;
        l_ovn_amt            NUMBER;
        l_trx_limit          NUMBER;
        l_overall_limit      NUMBER;
                
    BEGIN
        -- 1. Verifica Classificacao (customer_class_code) e Tipo (customer_type)
        SELECT customer_class_code, customer_type,sales_channel_code, account_name, attribute8, object_version_number
          INTO l_customer_class, l_customer_type,l_sales_channel_code,l_razao_social, l_attribute8, l_ovn_account
          FROM hz_cust_accounts
         WHERE cust_account_id = p_cust_account_id;
         
        -- Se classe for nula, OU tipo for nulo, OU canal for diferente de COC (incluindo vazio)
        IF l_customer_class IS NULL OR l_customer_type IS NULL OR NVL(l_sales_channel_code, 'X') != 'COC' 
            OR l_razao_social != p_dados.nome_cliente 
            OR (p_dados.institutionId IS NOT NULL AND NVL(l_attribute8, 'X') != p_dados.institutionId) THEN
            
            l_cust_account_rec.cust_account_id := p_cust_account_id;
            
            IF l_customer_class IS NULL THEN
                l_cust_account_rec.customer_class_code := 'ESCOLA';
            END IF;
            
            IF l_customer_type IS NULL THEN
                l_cust_account_rec.customer_type := 'R'; -- R = Externo
            END IF;
            
            -- Tratamento com NVL para evitar bug de valor nulo
            IF NVL(l_sales_channel_code, 'X') != 'COC' THEN
                l_cust_account_rec.sales_channel_code  := 'COC';
            END IF;  
            
            -- Atualiza o attribute8 apenas se tiver valor no payload
            IF p_dados.institutionId IS NOT NULL THEN
                l_cust_account_rec.attribute8 := p_dados.institutionId;
            END IF;
            
            l_cust_account_rec.account_name := p_dados.nome_cliente;
            
            print_log('  Atualizando Account com Classificacao, Tipo ou Canal de Vendas...');
            hz_cust_account_v2pub.update_cust_account(
                p_init_msg_list         => fnd_api.g_true,
                p_cust_account_rec      => l_cust_account_rec,
                p_object_version_number => l_ovn_account,
                x_return_status         => w_return_status,
                x_msg_count             => w_msg_count,
                x_msg_data              => w_msg_data
            );
            
             IF w_return_status <> fnd_api.g_ret_sts_success THEN
             
                print_log('##### update_cust_account status: ' || w_return_status); 
                print_log('  Falha ao atualizar conta do cliente: ' || w_msg_data);
                extrair_mensagens_api(w_msg_count);
                ok := FALSE;
            END IF;
        END IF;

        -- 2. Recuperar o Profile ID da conta (Nivel Header)
        DECLARE
            l_curr_profile_class_id NUMBER;
            l_ovn_profile           NUMBER;
            l_target_class_id       NUMBER;
            l_cust_profile_rec      hz_customer_profile_v2pub.customer_profile_rec_type;
        BEGIN
            SELECT cust_account_profile_id, profile_class_id, object_version_number
              INTO l_profile_id, l_curr_profile_class_id, l_ovn_profile
              FROM hz_customer_profiles
             WHERE cust_account_id = p_cust_account_id
               AND site_use_id IS NULL
               AND ROWNUM = 1;
               
            -- 2.1 Recupera ID do PERFIL ZZZ
            BEGIN
                SELECT profile_class_id INTO l_target_class_id
                  FROM hz_cust_profile_classes
                 WHERE name = 'PERFIL ZZZ'
                   AND ROWNUM = 1;
            EXCEPTION WHEN OTHERS THEN l_target_class_id := NULL;
            END;

            -- 2.2 Atualiza o profile_class_id se for diferente
            IF l_target_class_id IS NOT NULL AND NVL(l_curr_profile_class_id, -1) != l_target_class_id THEN
                l_cust_profile_rec.cust_account_profile_id := l_profile_id;
                l_cust_profile_rec.cust_account_id         := p_cust_account_id;
                l_cust_profile_rec.profile_class_id        := l_target_class_id;
                
                print_log('  Atualizando Classe do Customer Profile para PERFIL ZZZ...');
                hz_customer_profile_v2pub.update_customer_profile(
                    p_init_msg_list         => fnd_api.g_true,
                    p_customer_profile_rec  => l_cust_profile_rec,
                    p_object_version_number => l_ovn_profile,
                    x_return_status         => w_return_status,
                    x_msg_count             => w_msg_count,
                    x_msg_data              => w_msg_data
                );
                
                IF w_return_status <> fnd_api.g_ret_sts_success THEN
                    extrair_mensagens_api(w_msg_count, 'UPDATE_CUSTOMER_PROFILE');
                    ok := FALSE;
                END IF;
            END IF;

            -- 3. Verifica Limites (BRL)
            BEGIN
                SELECT cust_acct_profile_amt_id, object_version_number,
                       trx_credit_limit, overall_credit_limit
                  INTO l_amt_id, l_ovn_amt, l_trx_limit, l_overall_limit
                  FROM hz_cust_profile_amts
                 WHERE cust_account_profile_id = l_profile_id
                   AND currency_code = 'BRL'
                   AND site_use_id IS NULL
                   AND ROWNUM = 1;
                   
                -- Se ja tem o registro BRL, atualiza se o limite estiver nulo ou diferente
                IF NVL(l_trx_limit, 0) != 9999999.99 OR NVL(l_overall_limit, 0) != 9999999.99 THEN
                    l_profile_amt_rec.cust_acct_profile_amt_id := l_amt_id;
                    l_profile_amt_rec.cust_account_profile_id  := l_profile_id;
                    l_profile_amt_rec.cust_account_id          := p_cust_account_id;
                    l_profile_amt_rec.currency_code            := 'BRL';
                    l_profile_amt_rec.trx_credit_limit         := 9999999.99;
                    l_profile_amt_rec.overall_credit_limit     := 9999999.99;
                    
                    print_log('  Atualizando Limites de Credito BRL do Profile...');
                    hz_customer_profile_v2pub.update_cust_profile_amt(
                        p_init_msg_list         => fnd_api.g_true,
                        p_cust_profile_amt_rec  => l_profile_amt_rec,
                        p_object_version_number => l_ovn_amt,
                        x_return_status         => w_return_status,
                        x_msg_count             => w_msg_count,
                        x_msg_data              => w_msg_data
                    );
                    
                    IF w_return_status <> fnd_api.g_ret_sts_success THEN
                        extrair_mensagens_api(w_msg_count, 'UPDATE_CUST_PROFILE_AMT');
                        ok := FALSE;
                    END IF;
                END IF;
                
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    -- Se nao tem registro para a moeda BRL, cria um novo
                    l_profile_amt_rec.cust_account_profile_id := l_profile_id;
                    l_profile_amt_rec.cust_account_id         := p_cust_account_id;
                    l_profile_amt_rec.currency_code           := 'BRL';
                    l_profile_amt_rec.trx_credit_limit        := 9999999.99;
                    l_profile_amt_rec.overall_credit_limit    := 9999999.99;
                    l_profile_amt_rec.created_by_module       := g_created_by_module;
                    
                    print_log('  Criando Limites de Credito BRL do Profile...');
                    hz_customer_profile_v2pub.create_cust_profile_amt(
                        p_init_msg_list        => fnd_api.g_true,
                        p_cust_profile_amt_rec => l_profile_amt_rec,
                        x_cust_acct_profile_amt_id => l_amt_id,
                        x_return_status        => w_return_status,
                        x_msg_count            => w_msg_count,
                        x_msg_data             => w_msg_data
                    );
                    
                    IF w_return_status <> fnd_api.g_ret_sts_success THEN
                        extrair_mensagens_api(w_msg_count, 'CREATE_CUST_PROFILE_AMT');
                        ok := FALSE;
                    END IF;
            END;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                print_log('  AVISO: Customer Profile nao encontrado para a conta ' || p_cust_account_id);
        END;
    END atualizar_classificacao_limites;
    
    -- =========================================================================
    -- CLIENTE AR: CRIAR CONTA
    -- =========================================================================
    PROCEDURE criar_cliente(p_dados rec_dados_cliente) IS
        p_cust_account_rec     hz_cust_account_v2pub.cust_account_rec_type;
        p_person_rec           hz_party_v2pub.person_rec_type;
        p_organization_rec     hz_party_v2pub.organization_rec_type;
        p_customer_profile_rec hz_customer_profile_v2pub.customer_profile_rec_type;
        l_party_type           hz_parties.party_type%TYPE;
        l_existe               VARCHAR2(100) := 'N';
        l_account_number       hz_cust_accounts.account_number%TYPE := g_documento;
        l_party_id             NUMBER;
    BEGIN
        BEGIN
            SELECT account_number, cust_account_id, party_id
              INTO w_account_number, w_cust_account_id, l_party_id
              FROM hz_cust_accounts
             WHERE account_number = g_documento;

            IF l_party_id <> w_party_id THEN
                BEGIN
                    SELECT account_number, cust_account_id
                      INTO w_account_number, w_cust_account_id
                      FROM hz_cust_accounts
                     WHERE account_number = p_dados.numero_documento;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        w_cust_account_id := NULL;
                        
                    WHEN OTHERS THEN
                        w_cust_account_id := NULL;
                END;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                BEGIN
                    SELECT account_number, cust_account_id
                      INTO w_account_number, w_cust_account_id
                      FROM hz_cust_accounts
                     WHERE account_number = p_dados.numero_documento;
                EXCEPTION
                    WHEN NO_DATA_FOUND THEN
                        w_cust_account_id := NULL;
                        
                    WHEN OTHERS THEN
                        w_cust_account_id := NULL;
                END;
            WHEN OTHERS THEN
                w_cust_account_id := NULL;                
        END;

        IF w_cust_account_id IS NULL THEN
            BEGIN
                SELECT 'Y'
                  INTO l_existe
                  FROM hz_cust_accounts
                 WHERE account_number = g_documento
                   AND party_id      != w_party_id;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN l_existe := 'N';
                WHEN OTHERS THEN
                log_exception('N/A', 'Excecao suprimida intencionalmente ou nao tratada: ' || SQLERRM);
            END;

            l_account_number := CASE l_existe WHEN 'Y' THEN g_documento_raiz ELSE g_documento END;
            
        END IF;

        BEGIN
            SELECT DISTINCT hzp.party_type
              INTO l_party_type
              FROM hz_parties hzp
             WHERE hzp.party_id = w_party_id;
        EXCEPTION
            WHEN OTHERS THEN l_party_type := NULL;
        END;

        IF w_cust_account_id IS NULL THEN
            p_cust_account_rec.account_name      := p_dados.nome_cliente;
            p_cust_account_rec.account_number    := l_account_number;
            p_cust_account_rec.created_by_module := g_created_by_module;
            p_cust_account_rec.sales_channel_code      := 'COC';--2708'SGE'; --canal de venda

            -- Grava Institution Id apenas se vier preenchido
            IF p_dados.institutionId IS NOT NULL THEN
                p_cust_account_rec.attribute8 := p_dados.institutionId;
            END IF;
            
            recuperar_profile(p_customer_profile_rec);
            
            print_log('Chamando HZ_CUST_ACCOUNT_V2PUB.CREATE_CUST_ACCOUNT... party_id: ' || w_party_id);

            IF l_party_type = 'PERSON' THEN
                p_person_rec.person_first_name  := '';
                p_person_rec.person_last_name   := p_dados.nome_cliente;
                p_person_rec.party_rec.party_id := w_party_id;
                hz_cust_account_v2pub.create_cust_account(
                    p_init_msg_list        => fnd_api.g_true,
                    p_cust_account_rec     => p_cust_account_rec,
                    p_person_rec           => p_person_rec,
                    p_customer_profile_rec => p_customer_profile_rec,
                    p_create_profile_amt   => fnd_api.g_false,
                    x_cust_account_id      => w_cust_account_id,
                    x_account_number       => w_account_number,
                    x_party_id             => w_party_id,
                    x_party_number         => w_party_number,
                    x_profile_id           => w_profile_id,
                    x_return_status        => w_return_status,
                    x_msg_count            => w_msg_count,
                    x_msg_data             => w_msg_data);
                 
            ELSE
                p_organization_rec.party_rec.party_id := w_party_id;
                p_organization_rec.organization_name  := 'PSD Curitiba Operacao';
                hz_cust_account_v2pub.create_cust_account(
                    p_init_msg_list        => fnd_api.g_true,
                    p_cust_account_rec     => p_cust_account_rec,
                    p_organization_rec     => p_organization_rec,
                    p_customer_profile_rec => p_customer_profile_rec,
                    p_create_profile_amt   => fnd_api.g_false,
                    x_cust_account_id      => w_cust_account_id,
                    x_account_number       => w_account_number,
                    x_party_id             => w_party_id,
                    x_party_number         => w_party_number,
                    x_profile_id           => w_profile_id,
                    x_return_status        => w_return_status,
                    x_msg_count            => w_msg_count,
                    x_msg_data             => w_msg_data);
                                       
            END IF;

            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                print_log('##### create_cust_account status: ' || w_return_status); 
                print_log('  Falha ao criar conta do cliente: ' || w_msg_data);
                extrair_mensagens_api(w_msg_count);
                ok := FALSE;
                
            END IF;
        ELSE
            print_log('  hz_cust_accounts ja existe (cust_account_id: '||w_cust_account_id||'), reutilizando conta para criar site da filial.');
            atualizar_classificacao_limites(w_cust_account_id, p_dados);
        END IF;
    END criar_cliente;

    -- =========================================================================
    -- CLIENTE AR: CRIAR / ATUALIZAR SITE
    -- =========================================================================
    PROCEDURE criar_cliente_site(p_dados            rec_dados_cliente,
                                 p_cust_acct_site_rec OUT hz_cust_account_site_v2pub.cust_acct_site_rec_type,
                                 p_org_id           NUMBER) IS
        p_status                VARCHAR2(100);
        l_object_version_number NUMBER;
    BEGIN
        BEGIN
            SELECT cust_acct_site_id, party_site_id, created_by_module,
                   cust_account_id, org_id, global_attribute_category,
                   global_attribute2, global_attribute3, global_attribute4,
                   global_attribute5, global_attribute6, global_attribute8,
                   global_attribute9, global_attribute13,
                   hcas.status, object_version_number
              INTO w_cust_acct_site_id,
                   p_cust_acct_site_rec.party_site_id,
                   p_cust_acct_site_rec.created_by_module,
                   p_cust_acct_site_rec.cust_account_id,
                   p_cust_acct_site_rec.org_id,
                   p_cust_acct_site_rec.global_attribute_category,
                   p_cust_acct_site_rec.global_attribute2,
                   p_cust_acct_site_rec.global_attribute3,
                   p_cust_acct_site_rec.global_attribute4,
                   p_cust_acct_site_rec.global_attribute5,
                   p_cust_acct_site_rec.global_attribute6,
                   p_cust_acct_site_rec.global_attribute8,
                   p_cust_acct_site_rec.global_attribute9,
                   p_cust_acct_site_rec.global_attribute13,
                   p_status, l_object_version_number
              FROM (SELECT cust_acct_site_id, party_site_id, created_by_module,
                           cust_account_id, org_id, global_attribute_category,
                           global_attribute2, global_attribute3, global_attribute4,
                           global_attribute5, global_attribute6, global_attribute8,
                           global_attribute9, global_attribute13,
                           status, object_version_number
                      FROM hz_cust_acct_sites
                     WHERE cust_account_id = w_cust_account_id
                       AND party_site_id   = w_party_site_id
                       AND org_id          = p_org_id
                     ORDER BY DECODE(status, 'A', 1, 2)) hcas
             WHERE ROWNUM = 1;
        EXCEPTION
            WHEN OTHERS THEN
                w_cust_acct_site_id := NULL;
        END;

        IF w_cust_acct_site_id IS NULL THEN
            p_cust_acct_site_rec.party_site_id             := w_party_site_id;
            p_cust_acct_site_rec.created_by_module         := g_created_by_module;
            p_cust_acct_site_rec.cust_account_id           := w_cust_account_id;
            p_cust_acct_site_rec.org_id                    := p_org_id;
            p_cust_acct_site_rec.global_attribute_category := 'JL.BR.ARXCUDCI.Additional';
            p_cust_acct_site_rec.global_attribute2         := g_global_attribute9;
            p_cust_acct_site_rec.global_attribute3         := g_documento;--31082026 g_documento_raiz;
            p_cust_acct_site_rec.global_attribute4         := g_documento_filial;
            p_cust_acct_site_rec.global_attribute5         := g_documento_dv;
            p_cust_acct_site_rec.global_attribute6         := g_inscricao_estadual;
            p_cust_acct_site_rec.global_attribute8         := g_tipo_contribuite;
            p_cust_acct_site_rec.global_attribute9         := p_dados.codigosuframa;
            p_cust_acct_site_rec.global_attribute13        := g_indicador_ie_dest;

            fnd_msg_pub.initialize;
            p_cust_acct_site_rec.cust_acct_site_id := NULL;
            p_cust_acct_site_rec.status            := 'A';

            print_log('Chamando HZ_CUST_ACCOUNT_SITE_V2PUB.CREATE_CUST_ACCT_SITE...');
            hz_cust_account_site_v2pub.create_cust_acct_site(
                p_init_msg_list      => fnd_api.g_true,
                p_cust_acct_site_rec => p_cust_acct_site_rec,
                x_cust_acct_site_id  => w_cust_acct_site_id,
                x_return_status      => w_return_status,
                x_msg_count          => w_msg_count,
                x_msg_data           => w_msg_data);
                   
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                print_log('##### create_cust_acct_site status: ' || w_return_status); 
                print_log('  Falha ao criar Cust Acct Site: ' || w_msg_data);
                extrair_mensagens_api(w_msg_count);
                ok := FALSE;
            ELSE
                -- Forcar ativacao imediata: a API CREATE pode criar com status Inativo
                -- dependendo de configs do ambiente. Precisamos ativar ANTES de criar os Site Uses.
                DECLARE
                    l_act_rec hz_cust_account_site_v2pub.cust_acct_site_rec_type;
                    l_act_ovn NUMBER;
                BEGIN
                    SELECT object_version_number
                      INTO l_act_ovn
                      FROM hz_cust_acct_sites
                     WHERE cust_acct_site_id = w_cust_acct_site_id;

                    l_act_rec.cust_acct_site_id := w_cust_acct_site_id;
                    l_act_rec.status            := 'A';

                    hz_cust_account_site_v2pub.update_cust_acct_site(
                        fnd_api.g_true,
                        l_act_rec,
                        l_act_ovn,
                        w_return_status,
                        w_msg_count,
                        w_msg_data);

                    IF w_return_status <> fnd_api.g_ret_sts_success THEN
                        print_log('  AVISO: Falha ao ativar site recem-criado: ' || w_msg_data);
                        extrair_mensagens_api(w_msg_count);
                        ok := FALSE;
                    ELSE
                        print_log('  Cust Acct Site ' || w_cust_acct_site_id || ' criado e ativado com sucesso.');
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN
                        print_log('  AVISO: Erro ao ativar site recem-criado: ' || SQLERRM);
                END;
            END IF;

        ELSIF w_cust_acct_site_id IS NOT NULL AND p_status != 'A' THEN
            fnd_msg_pub.initialize;
            p_cust_acct_site_rec.cust_acct_site_id := w_cust_acct_site_id;
            p_cust_acct_site_rec.status             := 'A';

            hz_cust_account_site_v2pub.update_cust_acct_site(
                fnd_api.g_true,
                p_cust_acct_site_rec,
                l_object_version_number,
                w_return_status,
                w_msg_count,
                w_msg_data);                                   
            
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count);
                ok := FALSE;
                print_log('##### update_cust_acct_site status: ' || w_return_status); 
            
            END IF;
        ELSE
            print_log('  Cust Acct Site ja existe (id: '||w_cust_acct_site_id||'), reutilizando site existente.');
        END IF;
    END criar_cliente_site;

    -- =========================================================================
    -- CLIENTE AR: ATUALIZAR SITE
    -- =========================================================================
    PROCEDURE atualizar_cliente_site(p_cust_acct_site_rec OUT hz_cust_account_site_v2pub.cust_acct_site_rec_type,
                                 p_org_id NUMBER) IS
        l_object_version_number NUMBER;
        p_status                VARCHAR2(100);
    BEGIN
        BEGIN
        
            SELECT cust_acct_site_id, party_site_id, created_by_module,
                   cust_account_id, org_id, global_attribute_category,
                   global_attribute2, global_attribute3, global_attribute4,
                   global_attribute5, global_attribute6, global_attribute8,
                   global_attribute9, global_attribute13,
                   hcas.status, object_version_number
              INTO w_cust_acct_site_id,
                   p_cust_acct_site_rec.party_site_id,
                   p_cust_acct_site_rec.created_by_module,
                   p_cust_acct_site_rec.cust_account_id,
                   p_cust_acct_site_rec.org_id,
                   p_cust_acct_site_rec.global_attribute_category,
                   p_cust_acct_site_rec.global_attribute2,
                   p_cust_acct_site_rec.global_attribute3,
                   p_cust_acct_site_rec.global_attribute4,
                   p_cust_acct_site_rec.global_attribute5,
                   p_cust_acct_site_rec.global_attribute6,
                   p_cust_acct_site_rec.global_attribute8,
                   p_cust_acct_site_rec.global_attribute9,
                   p_cust_acct_site_rec.global_attribute13,
                   p_status, l_object_version_number
              FROM (SELECT cust_acct_site_id, party_site_id, created_by_module,
                           cust_account_id, org_id, global_attribute_category,
                           global_attribute2, global_attribute3, global_attribute4,
                           global_attribute5, global_attribute6, global_attribute8,
                           global_attribute9, global_attribute13,
                           status, object_version_number
                      FROM hz_cust_acct_sites
                     WHERE cust_account_id = w_cust_account_id
                       AND party_site_id   = w_party_site_id
                       AND org_id          = p_org_id
                     ORDER BY DECODE(status, 'A', 1, 2)) hcas
             WHERE ROWNUM = 1;
        EXCEPTION
            WHEN OTHERS THEN
                w_cust_acct_site_id := NULL;
        END;

        IF w_cust_acct_site_id IS NOT NULL THEN
            fnd_msg_pub.initialize;
            p_cust_acct_site_rec.cust_acct_site_id  := w_cust_acct_site_id;
            p_cust_acct_site_rec.global_attribute8   := g_tipo_contribuite;
            p_cust_acct_site_rec.global_attribute13  := g_indicador_ie_dest;
            p_cust_acct_site_rec.global_attribute6   := g_inscricao_estadual;
            
            IF p_status != 'A' THEN
                print_log('Reativando Cust Acct Site inativo (cust_acct_site_id: ' || w_cust_acct_site_id || ') ...');
                p_cust_acct_site_rec.status := 'A';
            END IF;

            hz_cust_account_site_v2pub.update_cust_acct_site(
                fnd_api.g_true,
                p_cust_acct_site_rec,
                l_object_version_number,
                w_return_status,
                w_msg_count,
                w_msg_data);
                                             
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                print_log('##### update_cust_acct_site status: ' || w_return_status);   
                print_log('  Falha ao atualizar Cust Acct Site: ' || w_msg_data);
                
            END IF;
        END IF;
        print_log('#####atualizar_cliente_site: ' || w_cust_acct_site_id);
    END atualizar_cliente_site;

    -- =========================================================================
    -- CLIENTE AR: CRIAR SITE USE (BILL_TO / SHIP_TO)
    -- =========================================================================
    PROCEDURE recuperar_site_use(p_cust_acct_site_id NUMBER,
                                  p_use_code          VARCHAR2,
                                  p_site_use_id       OUT NUMBER,
                                  p_org_id          NUMBER) IS
    BEGIN
        BEGIN
            SELECT hcsu.site_use_id
              INTO p_site_use_id
              FROM hz_cust_site_uses_all hcsu
             WHERE hcsu.cust_acct_site_id = p_cust_acct_site_id
               AND site_use_code          = p_use_code
               AND hcsu.status            = 'A'
               AND hcsu.org_id            = p_org_id;
        EXCEPTION
            WHEN OTHERS THEN
                p_site_use_id := NULL;
        END;
    END recuperar_site_use;

    -- -------------------------------------------------------------------------
    PROCEDURE criar_cliente_site_use(p_cust_site_use_rec    hz_cust_account_site_v2pub.cust_site_use_rec_type,
                                     p_customer_profile_rec hz_customer_profile_v2pub.customer_profile_rec_type,
                                     p_use_code             VARCHAR2,
                                     p_site_use_id          IN OUT NUMBER,
                                     p_org_id NUMBER) IS
        l_cust_site_use_rec hz_cust_account_site_v2pub.cust_site_use_rec_type;
        l_bill_site_use_id  NUMBER;
        l_saved_bill_to_id  NUMBER;
    BEGIN
        -- Salva o site_use_id recebido (quando SHIP_TO, ele contem o BILL_TO criado antes)
        l_saved_bill_to_id := p_site_use_id;
        
        recuperar_site_use(w_cust_acct_site_id, p_use_code, p_site_use_id, p_org_id);

        IF p_site_use_id IS NULL THEN
            l_cust_site_use_rec                   := p_cust_site_use_rec;
            l_cust_site_use_rec.cust_acct_site_id := w_cust_acct_site_id;
            l_cust_site_use_rec.created_by_module := g_created_by_module;
            l_cust_site_use_rec.site_use_code     := p_use_code;

            IF p_use_code = 'SHIP_TO' THEN
                recuperar_site_use(w_cust_acct_site_id, 'BILL_TO', l_bill_site_use_id, p_org_id);
                -- Fallback: se a consulta nao encontrou, usa o BILL_TO id salvo
                IF l_bill_site_use_id IS NULL THEN
                    l_bill_site_use_id := l_saved_bill_to_id;
                END IF;
                print_log('  bill_to_site_use_id para SHIP_TO: ' || l_bill_site_use_id || 
                           ' (cust_acct_site_id: ' || w_cust_acct_site_id || ')');
                l_cust_site_use_rec.bill_to_site_use_id := l_bill_site_use_id;
            END IF;

            fnd_msg_pub.initialize;
            print_log('Chamando HZ_CUST_ACCOUNT_SITE_V2PUB.CREATE_CUST_SITE_USE... ' || p_use_code);
            hz_cust_account_site_v2pub.create_cust_site_use(
                p_init_msg_list        => fnd_api.g_true,
                p_cust_site_use_rec    => l_cust_site_use_rec,
                p_customer_profile_rec => p_customer_profile_rec,
                p_create_profile       => fnd_api.g_true,
                p_create_profile_amt   => fnd_api.g_true,
                x_site_use_id          => p_site_use_id,
                x_return_status        => w_return_status,
                x_msg_count            => w_msg_count,
                x_msg_data             => w_msg_data);
print_log('##### create_cust_site_use status: ' || w_return_status);
            
            extrair_mensagens_api(w_msg_count);

            IF w_return_status <> 'S' THEN
                ok := FALSE;
            END IF;
        ELSE
            print_log('  Site use ' || p_use_code || ' ja existe (id: ' || p_site_use_id || ').');
        END IF;
    END criar_cliente_site_use;

    -- =========================================================================
    -- CLIENTE AR: ATUALIZAR ENDERECO
    -- =========================================================================
    PROCEDURE atualizar_endereco_cliente(p_dados rec_dados_cliente, p_org_id NUMBER) IS
        l_location_rec          hz_location_v2pub.location_rec_type;
        l_cust_account_rec      hz_cust_account_v2pub.cust_account_rec_type;
        l_customer_profile_rec  hz_customer_profile_v2pub.customer_profile_rec_type;
        l_object_version_number NUMBER;
    BEGIN
        hz_cust_account_v2pub.get_cust_account_rec(
            fnd_api.g_true,
            w_cust_account_id,
            l_cust_account_rec,
            l_customer_profile_rec,
            w_return_status,
            w_msg_count,
            w_msg_data);

        recuperar_profile(l_customer_profile_rec);

        -- Atualizar profiles (bloqueio de credito)
        FOR rec_site_update IN (SELECT hcp.cust_account_profile_id, hcp.site_use_id, hcpc.name
                                  FROM hz_customer_profiles hcp,
                                       hz_cust_profile_classes hcpc
                                 WHERE cust_account_id = w_cust_account_id
                                   AND hcp.profile_class_id = hcpc.profile_class_id
                                   AND ((site_use_id IN (SELECT site_use_id
                                                           FROM CLL_F255_AR_CUSTOMERS_V cfac --08092026 xxarco_ar_customers_v cfac
                                                          WHERE org_id        = p_org_id
                                                            AND party_id      = w_party_id
                                                            AND party_site_id = w_party_site_id
                                                            AND ROWNUM        = 1))
                                        OR (site_use_id IS NULL AND hcp.cust_account_id IN
                                            (SELECT hca.cust_account_id FROM apps.hz_cust_accounts hca
                                              WHERE hca.org_id = p_org_id)))
                                   AND hcp.status = 'A')
        LOOP
            IF p_dados.tipo_documento = 'CPF' THEN--1206 'F'
                l_customer_profile_rec.credit_hold := 'N';
            ELSE
                IF rec_site_update.name = 'B2C' THEN
                    l_customer_profile_rec.credit_hold := 'N';
                ELSE
                    l_customer_profile_rec.credit_hold := 'Y';
                END IF;
            END IF;

            l_customer_profile_rec.cust_account_profile_id := rec_site_update.cust_account_profile_id;
            l_customer_profile_rec.site_use_id             := rec_site_update.site_use_id;
            -- Usar o created_by_module exato do DB para evitar erro TCA
            -- "nao pode atualizar created_by_module" (coluna protegida apos criacao)
            SELECT object_version_number,
                   created_by_module
              INTO l_object_version_number,
                   l_customer_profile_rec.created_by_module
              FROM hz_customer_profiles
             WHERE cust_account_profile_id = rec_site_update.cust_account_profile_id;

            hz_customer_profile_v2pub.update_customer_profile(
                p_init_msg_list         => fnd_api.g_false,
                p_customer_profile_rec  => l_customer_profile_rec,
                p_object_version_number => l_object_version_number,
                x_return_status         => w_return_status,
                x_msg_count             => w_msg_count,
                x_msg_data              => w_msg_data);
            
            IF w_return_status <> fnd_api.g_ret_sts_success THEN
                extrair_mensagens_api(w_msg_count);
                ok := FALSE;
                print_log('##### update_customer_profile status: ' || w_return_status);            
                
            END IF;
        
        END LOOP;

        -- Atualizar location
        hz_location_v2pub.get_location_rec(
            fnd_api.g_true,
            w_location_id,
            l_location_rec,
            w_return_status,
            w_msg_count,
            w_msg_data);

        l_location_rec.address1    := p_dados.logradouro;
        l_location_rec.address2    := p_dados.numero;
        l_location_rec.address3    := p_dados.bairro;
        l_location_rec.address4    := NVL(p_dados.complemento, FND_API.G_MISS_CHAR);
        l_location_rec.city        := p_dados.cidade;
        l_location_rec.postal_code := p_dados.cep;
        l_location_rec.state       := p_dados.unidadefederativa;

        BEGIN
            SELECT object_version_number
              INTO l_object_version_number
              FROM hz_locations
             WHERE location_id = w_location_id;
        EXCEPTION
            WHEN OTHERS THEN l_object_version_number := 1;
        END;

        hz_location_v2pub.update_location(
            p_init_msg_list         => fnd_api.g_false,
            p_location_rec          => l_location_rec,
            p_object_version_number => l_object_version_number,
            x_return_status         => w_return_status,
            x_msg_count             => w_msg_count,
            x_msg_data              => w_msg_data);

        
        IF w_return_status <> fnd_api.g_ret_sts_success THEN
            extrair_mensagens_api(w_msg_count);
            ok := FALSE;
            print_log('##### UPDATE_LOCATION status: ' || w_return_status);
            
        END IF;
    END atualizar_endereco_cliente;

    -- =========================================================================
    -- ATUALIZAR SHIP SITE USE
    -- =========================================================================
    PROCEDURE atualizar_ship_site_use(p_site_use_id       NUMBER,
                                       p_cust_acct_site_id NUMBER,
                                       p_org_id        NUMBER) IS
        p_cust_site_use_rec     hz_cust_account_site_v2pub.cust_site_use_rec_type;
        l_object_version_number NUMBER := 1;
        l_bill_site_use_id      NUMBER;
        
    
    BEGIN    
        BEGIN
            SELECT object_version_number
              INTO l_object_version_number
              FROM hz_cust_site_uses_all hcsu
             WHERE cust_acct_site_id = p_cust_acct_site_id
               AND site_use_id       = p_site_use_id
               AND site_use_code     = 'SHIP_TO';
        EXCEPTION
            WHEN OTHERS THEN l_object_version_number := 1;
        END;

        p_cust_site_use_rec.site_use_id       := p_site_use_id;
        p_cust_site_use_rec.status            := 'A';
        p_cust_site_use_rec.cust_acct_site_id := p_cust_acct_site_id;
        p_cust_site_use_rec.site_use_code     := 'SHIP_TO';
        
        -- Buscar BILL_TO e reativar se estiver inativo
        DECLARE
            l_bill_status  VARCHAR2(1);
            l_bill_ovn     NUMBER;
            l_bill_rec     hz_cust_account_site_v2pub.cust_site_use_rec_type;
        BEGIN
            SELECT site_use_id, status, object_version_number
              INTO l_bill_site_use_id, l_bill_status, l_bill_ovn
              FROM hz_cust_site_uses_all
             WHERE cust_acct_site_id = p_cust_acct_site_id
               AND site_use_code     = 'BILL_TO'
               AND org_id            = p_org_id
               AND ROWNUM = 1;

            IF l_bill_status <> 'A' THEN
                print_log('Reativando BILL_TO inativo (site_use_id: ' || l_bill_site_use_id || ') antes do SHIP_TO...');
                l_bill_rec.site_use_id  := l_bill_site_use_id;
                l_bill_rec.status       := 'A';
                
                hz_cust_account_site_v2pub.update_cust_site_use(
                    p_init_msg_list         => fnd_api.g_true,
                    p_cust_site_use_rec     => l_bill_rec,
                    p_object_version_number => l_bill_ovn,
                    x_return_status         => w_return_status,
                    x_msg_count             => w_msg_count,
                    x_msg_data              => w_msg_data);
                    
                IF w_return_status <> fnd_api.g_ret_sts_success THEN
                    extrair_mensagens_api(w_msg_count, 'REACTIVATE_BILL_TO');
                    ok := FALSE;
                END IF;
            END IF;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                l_bill_site_use_id := NULL;
        END;
        -- FIM
        
        p_cust_site_use_rec.bill_to_site_use_id := l_bill_site_use_id;

        hz_cust_account_site_v2pub.update_cust_site_use(
            p_init_msg_list         => fnd_api.g_true,
            p_cust_site_use_rec     => p_cust_site_use_rec,
            p_object_version_number => l_object_version_number,
            x_return_status         => w_return_status,
            x_msg_count             => w_msg_count,
            x_msg_data              => w_msg_data);    
        
		IF w_return_status <> fnd_api.g_ret_sts_success THEN
           extrair_mensagens_api(w_msg_count);
            ok := FALSE;
            print_log('##### update_cust_site_use status: ' || w_return_status);
            
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            print_log('Erro atualizar_ship_site_use: ' || SQLERRM);
    END atualizar_ship_site_use;

    -- =========================================================================
    -- LIMPEZA DE CAMPOS (ISENTO/ISENTA)
    -- =========================================================================
    PROCEDURE atualizar_campos_variados(p_org_id NUMBER) IS
        l_contador NUMBER;
    BEGIN
        BEGIN
            SELECT COUNT(*)
              INTO l_contador
              FROM hz_cust_acct_sites_all
             WHERE party_site_id = w_party_site_id
               AND org_id        = p_org_id
               AND UPPER(global_attribute6) IN ('ISENTO', 'ISENTA');

            IF l_contador > 0 THEN
                UPDATE hz_cust_acct_sites_all
                   SET global_attribute6 = ''
                 WHERE party_site_id = w_party_site_id
                   AND org_id        = p_org_id
                   AND UPPER(global_attribute6) IN ('ISENTO', 'ISENTA');
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                log_exception('N/A', 'Excecao suprimida intencionalmente ou nao tratada: ' || SQLERRM);
        END;

        BEGIN
            UPDATE ap_supplier_sites_all
               SET global_attribute13 = ''
             WHERE location_id = w_location_id
               AND org_id      = p_org_id
               AND UPPER(global_attribute13) IN ('ISENTO', 'ISENTA');
        EXCEPTION
            WHEN OTHERS THEN
                log_exception('N/A', 'Excecao suprimida intencionalmente ou nao tratada: ' || SQLERRM);
        END;
    END atualizar_campos_variados;

    -- =========================================================================
    -- VINCULAR CLIENTE E FORNECEDOR NO RI (cll_f189)
    -- =========================================================================
    PROCEDURE vincular_cliente_forn_ri(p_document_type   VARCHAR2,
                                        p_document_number VARCHAR2,
                                        p_cust_acct_site_id NUMBER,
                                        p_org_id          NUMBER) IS
        r_cli           cll_f189_fiscal_entities_all%ROWTYPE;
        r_for           cll_f189_fiscal_entities_all%ROWTYPE;
    BEGIN
        print_log('INICIO ASSOCIACAO RI - Documento: ' || p_document_type || ' / ' || p_document_number);

        BEGIN
            SELECT * INTO r_cli
              FROM cll_f189_fiscal_entities_all
             WHERE org_id                   = p_org_id
               AND document_type            = p_document_type
               AND document_number          = p_document_number
               AND cust_acct_site_id        = p_cust_acct_site_id
               AND entity_type_lookup_code  = 'CUSTOMER_SITE'
               AND ROWNUM                   = 1;

            IF r_cli.business_vendor_id IS NULL THEN
                SELECT business_id INTO r_cli.business_vendor_id
                  FROM cll_f189_business_vendors
                 WHERE business_code = 'COMERCIAL'
                   AND ROWNUM        = 1;

                UPDATE cll_f189_fiscal_entities_all
                   SET last_updated_by    = fnd_global.user_id,
                       last_update_date   = SYSDATE,
                       business_vendor_id = r_cli.business_vendor_id
                 WHERE entity_id = r_cli.entity_id
                   AND org_id    = p_org_id;
            END IF;

            -- Tenta vincular o VENDOR_SITE correspondente
            BEGIN
                IF p_document_type = 'CNPJ' THEN
                    SELECT * INTO r_for
                      FROM cll_f189_fiscal_entities_all
                     WHERE org_id                  = p_org_id
                       AND document_type           = p_document_type
                       AND LPAD(document_number,15,0) = LPAD(p_document_number,15,0)
                       AND cust_acct_site_id       = p_cust_acct_site_id
                       AND entity_type_lookup_code = 'VENDOR_SITE'
                       AND ROWNUM                  = 1;
                ELSE
                    SELECT * INTO r_for
                      FROM cll_f189_fiscal_entities_all
                     WHERE org_id                  = p_org_id
                       AND document_type           = p_document_type
                       AND document_number         = p_document_number
                       AND cust_acct_site_id       = p_cust_acct_site_id
                       AND entity_type_lookup_code = 'VENDOR_SITE'
                       AND ROWNUM                  = 1;
                END IF;
                print_log('  Cliente ja vinculado ao fornecedor.');
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    BEGIN
                        IF p_document_type = 'CNPJ' THEN
                            SELECT * INTO r_for
                              FROM cll_f189_fiscal_entities_all
                             WHERE org_id                  = p_org_id
                               AND document_type           = p_document_type
                               AND LPAD(document_number,15,0) = LPAD(p_document_number,15,0)
                               AND entity_type_lookup_code = 'VENDOR_SITE'
                               AND cust_acct_site_id       IS NULL
                               AND ROWNUM                  = 1;
                        ELSE
                            SELECT * INTO r_for
                              FROM cll_f189_fiscal_entities_all
                             WHERE org_id                  = p_org_id
                               AND document_type           = p_document_type
                               AND document_number         = p_document_number
                               AND entity_type_lookup_code = 'VENDOR_SITE'
                               AND ROWNUM                  = 1;
                        END IF;

                        UPDATE cll_f189_fiscal_entities_all
                           SET last_updated_by   = fnd_global.user_id,
                               last_update_date  = SYSDATE,
                               cust_acct_site_id = p_cust_acct_site_id
                         WHERE entity_id = r_for.entity_id
                           AND org_id    = p_org_id;

                        print_log('  RI vinculado. entity_id: ' || r_for.entity_id);
                    EXCEPTION
                        WHEN OTHERS THEN
                            print_log('  Erro ao vincular RI: ' || SQLERRM);
                    END;
                WHEN OTHERS THEN
                    print_log('  Erro ao buscar vendor_site vinculado: ' || SQLERRM);
            END;
        EXCEPTION
            WHEN OTHERS THEN
                print_log('  Erro geral ao associar RI: ' || SQLERRM);
        END;

        print_log('FIM ASSOCIACAO RI');
    END vincular_cliente_forn_ri;
    
    PROCEDURE criar_atualizar_receipt_method(p_cust_account_id     NUMBER,
                                             p_site_use_id         NUMBER,
                                             p_receipt_method_name VARCHAR2 DEFAULT NULL) IS
        l_receipt_method_id NUMBER;
        l_existe            NUMBER;
        l_receipt_existente NUMBER;
    BEGIN
        print_log('UPSERT RECEIPT METHOD - Customer: ' || p_cust_account_id || ' ,Site: ' || p_site_use_id);
        --IF p_dados.receipt_method_name IS NULL THEN RETURN; END IF;
    
        -- Busca o receipt_method_id pelo nome
        SELECT receipt_method_id
          INTO l_receipt_method_id
          FROM ar_receipt_methods
         WHERE UPPER(name) = UPPER(p_receipt_method_name)
           AND NVL(end_date, SYSDATE + 1) > SYSDATE
           AND ROWNUM = 1;
    
        -- Verifica se nao existe vinculo
        SELECT COUNT(*)
          INTO l_existe
          FROM ra_cust_receipt_methods
         WHERE customer_id = p_cust_account_id
           AND receipt_method_id = l_receipt_method_id
           AND NVL(end_date, SYSDATE + 1) > SYSDATE;            
        
        IF l_existe = 0 THEN
            INSERT INTO ra_cust_receipt_methods
                (CUST_RECEIPT_METHOD_ID,customer_id, receipt_method_id, start_date,
                 primary_flag, creation_date, created_by,
                 last_update_date, last_updated_by, last_update_login,site_use_id)
            VALUES
                (RA_CUST_RECEIPT_METHODS_S.NEXTVAL,p_cust_account_id, l_receipt_method_id, TRUNC(SYSDATE),
                 'Y', SYSDATE, fnd_global.user_id,
                 SYSDATE, fnd_global.user_id, fnd_global.login_id,p_site_use_id);
    
            print_log('  Receipt Method vinculado: ' || l_receipt_method_id);
        ELSE
            SELECT MAX(CUST_RECEIPT_METHOD_ID)
              INTO l_receipt_existente
              FROM ra_cust_receipt_methods
             WHERE customer_id = p_cust_account_id
               AND receipt_method_id = l_receipt_method_id
               AND NVL(end_date, SYSDATE + 1) > SYSDATE;
               
            UPDATE ra_cust_receipt_methods SET                
                primary_flag = 'Y',
                last_update_date =  SYSDATE, 
                last_updated_by = fnd_global.user_id, 
                last_update_login = fnd_global.login_id
            WHERE                
                customer_id = p_cust_account_id
                AND receipt_method_id = l_receipt_method_id
                AND CUST_RECEIPT_METHOD_ID = l_receipt_existente;
                             
            print_log('  Receipt Method ' || l_receipt_existente || ' existente e ativado para este cliente.');
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            adicionar_erro('ERROR', 'Receipt Method nao encontrado: ' || p_receipt_method_name);
        WHEN OTHERS THEN
            adicionar_erro('ERROR', 'Erro ao vincular Receipt Method: ' || SQLERRM); 
    END criar_atualizar_receipt_method;

    -- =========================================================================
    -- PROCESSAR ORG-ESPECIFICO
    -- Executa todos os passos que dependem de org_id para uma unica org.
    -- Chamado em loop pela lookup XXARCO_ORG_RCPT_METHOD.
    -- =========================================================================
    PROCEDURE processar_org(p_dados               rec_dados_cliente,
                            p_org_id              NUMBER,
                            p_receipt_method_name VARCHAR2,
                            p_resp_code           VARCHAR2,
                            g_ret_validacao       NUMBER)
                            IS
        p_cust_site_use_rec    hz_cust_account_site_v2pub.cust_site_use_rec_type;
        p_cust_site_rec        hz_cust_account_site_v2pub.cust_acct_site_rec_type;
        p_customer_profile_rec hz_customer_profile_v2pub.customer_profile_rec_type;
        l_site_modif           VARCHAR2(20);
        l_inscricao_estadual   VARCHAR2(100);
        l_site_use_id          NUMBER;
        v_cust_acct_site_id    NUMBER;
        l_location_id          NUMBER;
    BEGIN
        print_log('=== Iniciando processamento org_id: ' || p_org_id || ' ===');

        -- Trocar contexto de org
        DECLARE
        l_user_id      NUMBER;
        l_resp_id      NUMBER;
        l_resp_appl_id NUMBER;
        BEGIN
            SELECT TO_NUMBER(attribute2) INTO l_resp_id
              FROM fnd_lookup_values
             WHERE lookup_type = 'XXARCO_RESP_INTEGRACOES'
               AND lookup_code = p_resp_code
               AND language    = 'PTB';
               
            SELECT application_id INTO l_resp_appl_id
              FROM fnd_responsibility_vl
             WHERE responsibility_id = l_resp_id;
             
            SELECT fu.user_id INTO l_user_id
              FROM fnd_user fu
             WHERE NVL(fu.end_date, SYSDATE + 1) > SYSDATE
               AND fu.user_name = 'INTEGRACAO';
               
            fnd_global.apps_initialize(l_user_id, l_resp_id, l_resp_appl_id);
            mo_global.set_policy_context('S', p_org_id);
            print_log('  Contexto inicializado: org=' || p_org_id || ' resp=' || l_resp_id);
        END;
        --apps.mo_global.set_policy_context('S', p_org_id);

        -- Resetar globals de site para evitar contaminacao entre orgs do loop
        w_cust_acct_site_id := NULL;
        w_site_use_id       := NULL;

        -- ------------------------------------------------------------------
        -- FORNECEDOR: site org-especifico
        -- ------------------------------------------------------------------

        l_site_modif := verif_mod_forn_site(g_documento_raiz, g_documento_filial, g_documento_dv,
                                            p_dados, g_inscricao_estadual,
                                            w_vendor_site_id, l_location_id, p_org_id);


        IF w_location_id IS NULL THEN
            w_location_id := l_location_id;
        END IF;

        IF l_site_modif = 'ATUALIZAR' THEN
            atualizar_fornecedor_site(p_dados, p_org_id);

        ELSIF l_site_modif = 'SITE_INEXISTENTE' THEN
            criar_fornecedor_site(p_dados, p_org_id);

        END IF;

        -- ------------------------------------------------------------------
        -- CLIENTE AR: site org-especifico
        -- ------------------------------------------------------------------
        IF p_dados.tipocontribuinte = 'S' THEN
            g_tipo_contribuite  := 'CONTRIBUINTE';
            g_indicador_ie_dest := '1';
        ELSE
            g_tipo_contribuite  := 'NAO CONTRIBUINTE';
            g_indicador_ie_dest := '9';
        END IF;

        IF g_ret_validacao = 1 THEN
            -- Cliente AR ja existe: verificar se endereco mudou
            l_site_modif := verif_mod_cliente_site(p_dados, l_inscricao_estadual, p_org_id);
            print_log('  Status site cliente (org ' || p_org_id || '): ' || l_site_modif);

            IF l_site_modif = 'ATUALIZAR' THEN            
                print_log('##### ATUALIZAR: ' || p_org_id);
                atualizar_cliente_site(p_cust_site_rec,p_org_id);
                atualizar_endereco_cliente(p_dados,p_org_id);
                criar_atualizar_contato(w_party_site_id, p_dados);
                atualizar_ship_site_use(w_site_use_id, w_cust_acct_site_id,p_org_id);
                -- Garante que o receipt method correto esta vinculado mesmo sem alteracao de endereco
                BEGIN
                    SELECT site_use_id INTO l_site_use_id
                      FROM hz_cust_site_uses_all
                     WHERE cust_acct_site_id = w_cust_acct_site_id
                       AND site_use_code     = 'BILL_TO'
                       AND status            = 'A'
                       AND ROWNUM            = 1;
                EXCEPTION WHEN OTHERS THEN l_site_use_id := NULL;
                END;
                criar_atualizar_receipt_method(w_cust_account_id, l_site_use_id, p_receipt_method_name);
                
            ELSIF l_site_modif = 'NAO_EXISTE_SHIP' THEN            
                print_log('##### NAO_EXISTE_SHIP: ' || p_org_id);
                -- Garante que hz_cust_acct_sites existe antes de criar as site uses
                -- Sempre chama criar_cliente_site: se inativo, reativa; se ausente, cria novo
                criar_cliente_site(p_dados, p_cust_site_rec, p_org_id);
                criar_cliente_site_use(p_cust_site_use_rec, p_customer_profile_rec, 'BILL_TO', l_site_use_id,p_org_id);
                criar_atualizar_receipt_method(w_cust_account_id, l_site_use_id, p_receipt_method_name);
                criar_cliente_site_use(p_cust_site_use_rec, p_customer_profile_rec, 'SHIP_TO', l_site_use_id,p_org_id);
                atualizar_cliente_site(p_cust_site_rec,p_org_id);
                atualizar_endereco_cliente(p_dados,p_org_id);
                criar_atualizar_contato(w_party_site_id, p_dados);
            ELSIF l_site_modif = 'SITE_EXISTE' THEN            
                print_log('##### SITE_EXISTE: ' || p_org_id);
                criar_atualizar_contato(w_party_site_id, p_dados);
				-- Garante que o receipt method correto esta vinculado mesmo sem alteracao de endereco
                BEGIN
                    SELECT site_use_id INTO l_site_use_id
                      FROM hz_cust_site_uses_all
                     WHERE cust_acct_site_id = w_cust_acct_site_id
                       AND site_use_code     = 'BILL_TO'
                       AND status            = 'A'
                       AND ROWNUM            = 1;
                EXCEPTION WHEN OTHERS THEN l_site_use_id := NULL;
                END;
                criar_atualizar_receipt_method(w_cust_account_id, l_site_use_id, p_receipt_method_name);
            END IF;
        ELSE
            -- Cliente AR nao existe: criar tudo   
            print_log('##### Cliente AR nao existe: ' || p_org_id || ' ===');
            criar_cliente_site(p_dados, p_cust_site_rec, p_org_id);
            criar_cliente_site_use(p_cust_site_use_rec, p_customer_profile_rec, 'BILL_TO', l_site_use_id,p_org_id);
            criar_atualizar_receipt_method(w_cust_account_id, l_site_use_id, p_receipt_method_name);
            criar_cliente_site_use(p_cust_site_use_rec, p_customer_profile_rec, 'SHIP_TO', l_site_use_id,p_org_id);
            criar_atualizar_contato(w_party_site_id, p_dados);
        END IF;

        -- ------------------------------------------------------------------
        -- LIMPEZA DE CAMPOS (ISENTO/ISENTA) para esta org
        -- ------------------------------------------------------------------
        atualizar_campos_variados(p_org_id);

        -- ------------------------------------------------------------------
        -- VINCULAR RI para esta org
        -- ------------------------------------------------------------------
        BEGIN
            SELECT cust_acct_site_id
              INTO v_cust_acct_site_id
              FROM hz_cust_acct_sites hcas
             WHERE cust_account_id = w_cust_account_id
               AND org_id          = p_org_id
               AND party_site_id   = w_party_site_id;
        EXCEPTION
            WHEN OTHERS THEN v_cust_acct_site_id := NULL;
        END;

        IF NVL(p_cust_site_rec.cust_acct_site_id, v_cust_acct_site_id) IS NOT NULL THEN
            vincular_cliente_forn_ri(p_dados.tipo_documento,
                                     g_documento_inteiro,
                                     NVL(p_cust_site_rec.cust_acct_site_id, v_cust_acct_site_id),
                                     p_org_id);
        END IF;

        print_log('=== Fim processamento org_id: ' || p_org_id || ' ===');
    EXCEPTION
        WHEN OTHERS THEN
            adicionar_erro('ERROR', 'Erro na org ' || p_org_id || ': ' || SQLERRM);
            print_log('ERRO na org ' || p_org_id || ': ' || SQLERRM);
            RAISE; -- Propaga o erro: rollback total no processar_sincrono
    END processar_org;
    -- =========================================================================
    -- PROCEDURE PRINCIPAL DE NEGOCIO (SINCRONA)
    -- Recebe o record ja populado e executa toda a logica de criacao/atualizacao
    -- =========================================================================
    PROCEDURE principal_sincrono(p_dados rec_dados_cliente) IS
        p_cust_site_use_rec    hz_cust_account_site_v2pub.cust_site_use_rec_type;
        p_cust_site_rec        hz_cust_account_site_v2pub.cust_acct_site_rec_type;
        p_customer_profile_rec hz_customer_profile_v2pub.customer_profile_rec_type;
        l_documento_ok         BOOLEAN;
        l_cidade_ok            BOOLEAN;
        l_estado_ok            BOOLEAN;
        p_location_id          NUMBER;
        v_cust_acct_site_id    NUMBER;
        l_site_modif           VARCHAR2(20);
        l_retorno              VARCHAR2(1);
        l_inscricao_estadual   VARCHAR2(100);
        g_ret_validacao        NUMBER;
    BEGIN
        -- Limpa variaveis globais antes de comecar (previne lixo da execucao anterior)
        inicializar_variaveis;

        print_log('INICIO PROCESSAMENTO SINCRONO - documento: ' || p_dados.numero_documento);

        -- Variaveis de controle locais da procedure
        l_documento_ok       := FALSE;
        l_cidade_ok          := FALSE;
        l_estado_ok          := FALSE;
        g_inscricao_estadual := UPPER(TRANSLATE(p_dados.inscricao_estadual, '.-/', '   '));

        -- Formatar documento
        IF p_dados.tipo_documento = 'CNPJ' THEN --1206 'J'
            g_documento_inteiro := LPAD(p_dados.numero_documento, 14, '0');
            
        ELSIF p_dados.tipo_documento = 'CPF' THEN --1206 'F'
            g_documento_inteiro := LPAD(p_dados.numero_documento, 11, '0');
        ELSE
            g_documento_inteiro := p_dados.numero_documento;
        END IF;

        -- Validar documento
        IF (p_dados.tipo_documento = 'CNPJ') THEN
            l_documento_ok := validar_documento(p_dados.tipo_documento, g_documento_inteiro);        
        ELSIF (p_dados.tipo_documento = 'CPF') THEN
            l_documento_ok := validar_documento_cpf(p_dados.tipo_documento, g_documento_inteiro);
        END IF;
        -- 1 true / 0 false
        --1 cll_f189_digit_calc_pkg 1 SUCESSO / 0 ERRO
        IF NOT l_documento_ok THEN            
            RETURN;
        END IF;

        -- Decompor documento (raiz, filial, dv)
        recuperar_documentos(p_dados.tipo_documento, g_documento_inteiro,
                             g_documento, g_documento_raiz, g_documento_filial, g_documento_dv);                
        
        -- Tipo do vendor (para definir vendor_site_code)
        BEGIN
            SELECT vendor_type_lookup_code
              INTO g_vendor_type
              FROM ap_suppliers
             WHERE segment1 = g_documento_raiz;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN g_vendor_type := 'N';
        END;

        IF g_vendor_type = 'EMPLOYEE' THEN
            w_vendor_site_code := 'OFFICE';
        ELSE
            w_vendor_site_code := g_documento_filial || '-' || g_documento_dv;
        END IF;

        -- Pais
        g_country       := 'BR';
        g_cidade        := p_dados.cidade;
        g_estado        := p_dados.unidadefederativa;

        -- Validar estado e cidade (apenas para Brasil)
        l_estado_ok := validar_estado(p_dados.unidadefederativa);
        l_cidade_ok := validar_cidade(p_dados.cidade);

        -- Localizar registros existentes
        g_ret_validacao := validar_fornecedor;

        print_log('----------------------------------------------------------------');
        print_log('  Resultado validacao   : ' || g_ret_validacao);
        print_log('  Documento (raiz)      : ' || g_documento);
        print_log('  Documento (completo)  : ' || g_documento_inteiro);
        print_log('  Nome                  : ' || p_dados.nome_cliente);
        print_log('  Vendor site code      : ' || w_vendor_site_code);
        print_log('  Vendor id             : ' || w_vendor_id);
        print_log('  Party id              : ' || w_party_id);
        print_log('  Party site id         : ' || w_party_site_id);
        print_log('  Location id           : ' || w_location_id);         
        print_log('----------------------------------------------------------------');

        -- Criar ou atualizar location e party site conforme necessario
        IF w_party_site_id IS NULL AND g_ret_validacao = 3 THEN
            criar_localizacao(p_dados, w_location_id);
            criar_party_site;
        ELSIF w_party_site_id IS NOT NULL AND g_ret_validacao = 2 THEN
            atualizar_localizacao(p_dados);
            atualizar_party(p_dados);
        ELSIF w_party_site_id IS NULL AND g_ret_validacao = 2 THEN
            criar_localizacao(p_dados, w_location_id);
            criar_party_site;
        END IF;

         --Atualizar party_site_name se estiver nulo
        IF w_party_site_id IS NOT NULL THEN
            DECLARE
                l_ps_name VARCHAR2(20);
                l_ovn_ps  NUMBER;
                l_ps_rec  hz_party_site_v2pub.party_site_rec_type;
            BEGIN
                SELECT party_site_name, object_version_number
                  INTO l_ps_name, l_ovn_ps
                  FROM hz_party_sites
                 WHERE party_site_id = w_party_site_id;
                IF l_ps_name IS NULL THEN
                    l_ps_rec.party_site_id   := w_party_site_id;
                    l_ps_rec.party_site_name := w_vendor_site_code;
                    
                    print_log('  Atualizando party_site_name para...' || w_vendor_site_code );
                    hz_party_site_v2pub.update_party_site(
                        p_init_msg_list         => fnd_api.g_true,
                        p_party_site_rec        => l_ps_rec,
                        p_object_version_number => l_ovn_ps,
                        x_return_status         => w_return_status,
                        x_msg_count             => w_msg_count,
                        x_msg_data              => w_msg_data
                    );
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    print_log('  Aviso: erro ao atualizar party_site_name - ' || SQLERRM);
            END;
        END IF;
        
        -- Tratar homonimos para PF (CPF)
        w_nm_cliente := NULL;
        w_qty_vendor := 0;
        IF p_dados.tipo_documento = 'CPF' THEN --1206 'F'
            BEGIN
                SELECT COUNT(*)
                  INTO w_qty_vendor
                  FROM ap_suppliers
                 WHERE UPPER(vendor_name)                    =  UPPER(p_dados.nome_cliente)
                   AND segment1                              <> g_documento_raiz
                   AND NVL(vendor_type_lookup_code,'NONEMP') <> 'EMPLOYEE';

                IF w_qty_vendor = 0 THEN
                    SELECT COUNT(*)
                      INTO w_qty_vendor
                      FROM ap_suppliers
                     WHERE UPPER(vendor_name)                    = UPPER(p_dados.nome_cliente)
                       AND segment1                              = g_documento_raiz
                       AND NVL(vendor_type_lookup_code,'NONEMP') <> 'EMPLOYEE';
                    IF w_qty_vendor > 0 THEN w_qty_vendor := 0; END IF;
                END IF;

                IF w_qty_vendor = 0 THEN
                    SELECT COUNT(*)
                      INTO w_qty_vendor
                      FROM hz_parties
                     WHERE UPPER(party_name) = UPPER(p_dados.nome_cliente)
                       AND party_type        = 'ORGANIZATION';
                END IF;
            END;

            IF w_qty_vendor > 0 THEN
                w_nm_cliente := UPPER(p_dados.nome_cliente);
                
            END IF;
        END IF;

        -- Criar fornecedor se nao existir (global - executado uma vez)
        IF existe_fornecedor(w_party_id, w_vendor_id) = 'N' THEN
            criar_fornecedor(p_dados, l_retorno);
            IF NOT ok THEN
                ROLLBACK;
                RETURN;
            END IF;
        END IF;

        -- Cliente AR (conta global - executado uma vez)
        IF g_ret_validacao != 1 THEN  -- inclui g_ret_validacao = 2 (vendor AP sem conta AR)
            criar_cliente(p_dados);
            print_log('Cliente AR');
        ELSE
            print_log('Cliente AR ja existe');
            -- Se cliente AR ja existe, precisamos recuperar o ID da conta e atualizar limites/classificacao
            BEGIN
                SELECT cust_account_id INTO w_cust_account_id
                  FROM hz_cust_accounts
                 WHERE party_id = w_party_id
                   AND status = 'A'
                   AND ROWNUM = 1;
                print_log('  Cust Account id       : ' || w_cust_account_id);  
                IF w_cust_account_id IS NOT NULL THEN
                    atualizar_classificacao_limites(w_cust_account_id,p_dados);
                END IF;
            EXCEPTION
                WHEN OTHERS THEN
                    print_log('ERRO ao buscar cust_account_id para o party_id ' || w_party_id || ' : ' || SQLERRM);
            END;
        END IF;

        -- ------------------------------------------------------------------
        -- LOOP MULTI-ORG: busca orgs e receipt methods da lookup
        -- Para adicionar nova empresa ou alterar receipt method,
        -- basta alterar a lookup XXARCO_ORG_RCPT_METHOD.
        -- ------------------------------------------------------------------
        print_log('INICIO LOOP MULTI-ORG');
        FOR rec IN (
            SELECT TO_NUMBER(flv.lookup_code) AS org_id,
                   flv.description            AS receipt_method_name,
                   flv.tag                    AS resp_code
              FROM fnd_lookup_values flv
             WHERE flv.lookup_type  = 'XXARCO_ORG_RCPT_METHOD'
               AND flv.enabled_flag = 'Y'
               AND flv.language     = 'PTB'
               AND NVL(flv.end_date_active, SYSDATE + 1) > SYSDATE
             ORDER BY flv.lookup_code
        ) LOOP
            --Passando g_ret_validacao como paramentro porque estava zerando a variavel para atualizacao
            processar_org(p_dados, rec.org_id, rec.receipt_method_name, rec.resp_code,g_ret_validacao);
        END LOOP;
        print_log('FIM LOOP MULTI-ORG');

        -- ------------------------------------------------------------------
        -- POS-PROCESSAMENTO GLOBAL (apos todas as orgs)
        -- ------------------------------------------------------------------

        -- Corrigir homonimo PF apos criacao
        IF p_dados.tipo_documento = 'CPF' AND w_nm_cliente IS NOT NULL THEN --1206 'F'
            BEGIN
                UPDATE ap_suppliers           SET vendor_name       = w_nm_cliente WHERE vendor_id      = w_vendor_id;
                UPDATE hz_parties             SET party_name        = w_nm_cliente WHERE party_id        = w_party_id;
                UPDATE hz_organization_profiles SET organization_name = w_nm_cliente WHERE party_id     = w_party_id;
                UPDATE hz_cust_accounts       SET account_name      = w_nm_cliente WHERE cust_account_id = w_cust_account_id;
                print_log('Homonimo PF corrigido. vendor_id: ' || w_vendor_id);
            EXCEPTION
                WHEN OTHERS THEN
                    adicionar_erro('ERROR', 'Erro ao corrigir homonimo: ' || SQLERRM, FALSE);
            END;
        END IF;

        print_log('FIM PROCESSAMENTO SINCRONO: ' || case when ok then 'true' else 'false' end);
    EXCEPTION
        WHEN OTHERS THEN
            ok := FALSE;
            adicionar_erro('ERROR', 'Erro inesperado no processamento: ' || SQLERRM);
            print_log('ERRO INESPERADO: ' || SQLERRM);
            RAISE;
    END principal_sincrono;

    -- =========================================================================
    -- MONTAR RETORNO JSON
    -- =========================================================================
    FUNCTION montar_retorno_json(p_status VARCHAR2,p_status_code NUMBER) RETURN CLOB IS
        l_json        CLOB;
        l_mensagens   VARCHAR2(32767) := '';
        l_sep         VARCHAR2(1)     := '';
        l_count       NUMBER;
    BEGIN
        -- Montar array de mensagens
        l_count := NVL(g_rec_retorno."registros"(1)."linhas"(1)."mensagens".COUNT, 0);
        FOR i IN 1 .. l_count LOOP
            IF g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(i)."mensagem" IS NOT NULL THEN
                l_mensagens := l_mensagens || l_sep ||
                               '{"type":"' ||
                               g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(i)."tipoMensagem" ||
                               '","message":"' ||
                               REPLACE(g_rec_retorno."registros"(1)."linhas"(1)."mensagens"(i)."mensagem",'"', '\"') ||
                               '"}';
                l_sep := ',';
            END IF;
        END LOOP;

        l_json := '{'                                                            ||
                  '"code":"'         || p_status_code                 || '",'      ||
                  '"status":"'         || p_status                 || '",'      ||
                  '"account":"'      || NVL(g_documento,'null')      || '",'      ||
                  --'"party_id":'        || NVL(TO_CHAR(w_party_id), 'null')  || ','  ||
                  --'"vendor_id":'       || NVL(TO_CHAR(w_vendor_id),'null')  || ','  ||
                  --'"vendor_site_id":'  || NVL(TO_CHAR(w_vendor_site_id),'null') || ',' ||
                  --'"cust_account_id":' || NVL(TO_CHAR(w_cust_account_id),'null') || ',' ||                  
                  '"messages":['      || l_mensagens || ']'                     ||
                  '}';

        RETURN l_json;
    END montar_retorno_json;    
    
    PROCEDURE atualizar_retorno_processamento(p_status IN VARCHAR2,
                                              p_retorno_json IN CLOB,
                                              p_id_integracao_detalhe IN NUMBER,
                                              p_document_number IN VARCHAR2) IS
    
    BEGIN
        print_log('================================================================');
        print_log('Atualizando tabela de INTEGRACAO:  Status - ' || p_status || ' ID - ' || p_id_integracao_detalhe );
        print_log('================================================================');
        BEGIN
            update apps.xxpsd_integracao_detalhe
                set IE_STATUS_PROCESSAMENTO = p_status,
                DS_DADOS_RETORNO = p_retorno_json,
                DT_FIM_PROCESSAMENTO = systimestamp,
                CHAVE = p_document_number
                WHERE ID_INTEGRACAO_DETALHE = p_id_integracao_detalhe;
        EXCEPTION
            WHEN OTHERS THEN
                print_log('ERRO[ADD_ERRO]:' || SQLERRM);
        END;
    
    END atualizar_retorno_processamento;
    -- =========================================================================
    -- PROCEDURE PUBLICA PRINCIPAL (SINCRONA)
    -- =========================================================================
    PROCEDURE processar_sincrono(p_json_payload IN  CLOB,
                                  x_retorno_json OUT CLOB,
                                  x_status       OUT VARCHAR2) IS
        l_dados   rec_dados_cliente;
        l_errbuf  VARCHAR2(1000);
        l_id_integracao_detalhe number;
    BEGIN
        -- 1. Inicializar ambiente EBS
        ok       := TRUE;
        g_escopo := 'CAD_CLIENTE_PIC_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS');
        init_retorno;
        initialize;

        IF NOT ok THEN
            x_status       := 'ERRO';
            x_retorno_json := montar_retorno_json('ERROR',500);
            RETURN;
        END IF;

        print_log('================================================================');
        print_log('INICIO PROCESSAR_SINCRONO: ' || TO_CHAR(SYSDATE, 'DD/MM/YYYY HH24:MI:SS'));
        print_log('================================================================');

        -- 2. Salvar o payload para rastreabilidade (staging)
        BEGIN
            xxpsd_pck_sincro_cliente.registrar(
                p_cd_interface          => 'CADASTRO_CLIENTE_PIC',
                p_cd_chave_interface    => '20',
                p_cd_sistema_origem     => 'INTEGRADOR',
                p_cd_sistema_destino    => 'EBS',
                p_ds_dados_requisicao   => p_json_payload,
                p_id_transacao          => NULL,
                p_cd_programa           => 'CADASTRO_CLIENTE_PIC',
                p_id_integracao_detalhe => l_id_integracao_detalhe,
                p_ds_dados_retorno      => l_errbuf);
            print_log('Payload gravado na staging. Status: ' || l_errbuf);
        EXCEPTION
            WHEN OTHERS THEN
                -- Nao bloqueia o processamento, apenas loga
                print_log('AVISO: Falha ao gravar staging: ' || SQLERRM);
        END;

        -- 3. Parsear JSON -> record        
        parse_json(p_json_payload, l_dados);

        IF NOT ok THEN            
            ROLLBACK; -- 1. Desfaz tudo que a parse_json possa ter tentado
            x_status       := 'ERRO';
            x_retorno_json := montar_retorno_json('ERROR',500);
            
            --ATUALIZAR RETORNO NA TABELA xxpsd_integracao_detalhe
            atualizar_retorno_processamento(x_status,
                                            x_retorno_json,
                                            l_id_integracao_detalhe,
                                            l_dados.numero_documento);
            COMMIT; -- 2. Salva o status de ERRO na staging
            RETURN;
        END IF;

        -- 4. Executar logica principal
        principal_sincrono(l_dados);
        print_log('status atual: ' || case when ok then 'true' else 'false' end);
        
        -- 5. Tratar resultado
        IF ok THEN
            COMMIT; -- 1. Salva os dados de negocio no Oracle TCA
            g_rec_retorno."retornoProcessamento"                  := 'SUCESS';
            g_rec_retorno."registros"(1)."retornoProcessamento"   := 'SUCESS';
            x_status       := 'SUCESSO';
            x_retorno_json := montar_retorno_json('SUCESS',200);
            print_log('SUCESSO!!!');
            
            --ATUALIZAR RETORNO NA TABELA xxpsd_integracao_detalhe
            atualizar_retorno_processamento(x_status,
                                            x_retorno_json,
                                            l_id_integracao_detalhe,
                                            l_dados.numero_documento);            
            COMMIT; -- 2. Salva o status de SUCESSO na staging
            
        ELSE
            ROLLBACK; -- 1. Desfaz todos os dados de negocio no Oracle TCA (Nada de clientes quebrados)
            print_log('ERRO - ROLLBACK executado.');
            
            g_rec_retorno."retornoProcessamento"                  := 'ERROR';
            g_rec_retorno."registros"(1)."retornoProcessamento"   := 'ERROR';
            x_status       := 'ERRO';
            x_retorno_json := montar_retorno_json('ERROR',500);
            
            --ATUALIZAR RETORNO NA TABELA xxpsd_integracao_detalhe
            atualizar_retorno_processamento(x_status,
                                            x_retorno_json,
                                            l_id_integracao_detalhe,
                                            l_dados.numero_documento);
            COMMIT; -- 2. Salva o status de ERRO na staging
        END IF;

        print_log('================================================================');
        print_log('FIM PROCESSAR_SINCRONO: ' || TO_CHAR(SYSDATE, 'DD/MM/YYYY HH24:MI:SS'));
        print_log('================================================================');

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK; -- 1. Desfaz tudo
            
            g_rec_retorno."retornoProcessamento"                  := 'ERROR';
            g_rec_retorno."registros"(1)."retornoProcessamento"   := 'ERROR';
            x_status       := 'ERRO';
            x_retorno_json := montar_retorno_json('ERROR',500);
            adicionar_erro('ERROR', 'Erro fatal no processamento: ' || SQLERRM, FALSE);
            
            atualizar_retorno_processamento(x_status,
                                            x_retorno_json,
                                            l_id_integracao_detalhe,
                                            l_dados.numero_documento);
            COMMIT; -- 2. Salva o status de ERRO na staging
            print_log('Erro Processar Sincrono :' || SQLERRM);
            
            xxpsd_pck_logger.log_error(
                p_log    => 'Excecao nao tratada em processar_sincrono: ' || SQLERRM,
                p_escopo => g_escopo);                                            
            BEGIN
                ROLLBACK;
            EXCEPTION
                WHEN OTHERS THEN
                    print_log('AVISO: Falha no ROLLBACK: ' || SQLERRM);
                    -- Nao relanca: garante que o JSON retorna de qualquer forma
            END;
    END processar_sincrono;
    
    

END XXARCO_AR_INT_CUSTOMER_PKG;
/