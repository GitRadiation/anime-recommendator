-- Eliminar tablas existentes en el orden correcto (primero la intermedia)
DROP TABLE IF EXISTS user_score;
DROP TABLE IF EXISTS user_details;
DROP TABLE IF EXISTS anime_dataset;

CREATE TABLE anime_dataset (
    anime_id INTEGER PRIMARY KEY,
    name VARCHAR(255),
    score NUMERIC(4,2), -- Para valores como 8.75
    genres TEXT[], -- Lista de géneros como array
    keywords TEXT[], -- Lista larga de palabras clave como array
    type VARCHAR(50),
    episodes REAL, -- Puede ser decimal como 26.0
    aired SMALLINT, -- Año como '1998'
    premiered VARCHAR(20), -- Ej: 'spring'
    status VARCHAR(50),
    producers TEXT[], -- Lista de productores como array
    studios VARCHAR(100),
    source VARCHAR(50),
    rating VARCHAR(100),
    rank INTEGER,
    popularity INTEGER,
    favorites INTEGER,
    scored_by INTEGER,
    members INTEGER,
    duration_class VARCHAR(20), -- Nueva columna basada en ejemplo
    episodes_class VARCHAR(20)  -- Nueva columna basada en ejemplo
);

CREATE TABLE user_details (
    mal_id INTEGER PRIMARY KEY,
    username VARCHAR(255), -- Necesario para la relación con user_score
    gender VARCHAR(10),
    age_group VARCHAR(10), -- Grupo de edad: "young", "adult", "senior"
    days_watched NUMERIC(10,2), -- Tiempo en días que el usuario ha visto anime
    mean_score NUMERIC(4,2), -- Promedio de calificación
    watching INTEGER, -- Número de animes que está viendo
    completed INTEGER, -- Número de animes que ha completado
    on_hold INTEGER, -- Número de animes en espera
    dropped INTEGER, -- Número de animes descartados
    plan_to_watch INTEGER, -- Número de animes que planea ver
    total_entries INTEGER, -- Total de entradas en su lista
    rewatched INTEGER, -- Número de animes que ha vuelto a ver
    episodes_watched INTEGER -- Número total de episodios vistos
);

-- Crear tabla user_score (tabla intermedia para la relación N:N entre user_details y anime_dataset)
CREATE TABLE user_score (
    user_id INTEGER,
    anime_id INTEGER,
    rating VARCHAR(10), -- Calificación categorizada: "low", "medium", "high"
    PRIMARY KEY (user_id, anime_id),  -- Clave primaria compuesta
    FOREIGN KEY (user_id) REFERENCES user_details(mal_id),
    FOREIGN KEY (anime_id) REFERENCES anime_dataset(anime_id)
);

DROP TABLE IF EXISTS rules CASCADE;
DROP TABLE IF EXISTS rule_conditions CASCADE;

CREATE TABLE rules (
    rule_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    target_value INTEGER NOT NULL
);

CREATE TABLE rule_conditions (
    condition_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    rule_id UUID NOT NULL,
    table_name VARCHAR(50) NOT NULL CHECK (table_name IN ('user_details', 'anime_dataset')), 
    column_name VARCHAR(100) NOT NULL,
    operator VARCHAR(10) NOT NULL CHECK (operator IN ('>=', '<=', '>', '<', '=', '==', '!=')),
    value_text TEXT,
    value_numeric NUMERIC,
    FOREIGN KEY (rule_id) REFERENCES rules(rule_id) ON DELETE CASCADE,
    CHECK (
        value_text IS NOT NULL OR value_numeric IS NOT NULL
    )
);



-- Índice para acelerar consultas que filtran por rule_id en rule_conditions
CREATE INDEX idx_rule_conditions_rule_id ON rule_conditions(rule_id);

-- Índice para optimizar consultas que filtran por tabla y columna
CREATE INDEX idx_rule_conditions_table_column ON rule_conditions(table_name, column_name);

-- Índice para optimizar consultas que ordenan o filtran por target_value en rules
CREATE INDEX idx_rules_target_value ON rules(target_value);

DROP FUNCTION IF EXISTS get_rules_series;

CREATE OR REPLACE FUNCTION get_rules_series(input_data JSONB) 
RETURNS TABLE(anime_id INT, nombre TEXT, cantidad INTEGER) AS $$
DECLARE
    user_record RECORD;
    anime_record RECORD;
    rule_record RECORD;
    condition_record RECORD;
    user_conditions_met BOOLEAN;
    anime_conditions_met BOOLEAN;
    condition_met BOOLEAN;
    array_check_result BOOLEAN;
    user_data JSONB;
    anime_list JSONB;
    anime_item JSONB;
    temp_anime_id INT;
    temp_anime_name TEXT;
BEGIN
    -- Extraer datos del usuario del JSON de entrada
    user_data := input_data->'user';
    -- Extraer lista de animes del JSON de entrada
    anime_list := input_data->'anime_list';
    
    -- Crear tabla temporal para almacenar resultados de animes que cumplen las reglas
    CREATE TEMP TABLE temp_results (
        anime_id INT,
        nombre TEXT
    ) ON COMMIT DROP;
    
    -- Iterar sobre cada regla definida en la tabla "rules"
    FOR rule_record IN 
        SELECT DISTINCT r.rule_id, r.target_value 
        FROM rules r
        INNER JOIN rule_conditions rc ON r.rule_id = rc.rule_id
    LOOP
        -- Inicializar variable para verificar si el usuario cumple todas las condiciones de esta regla
        user_conditions_met := TRUE;
        
        -- Verificar las condiciones que aplican al usuario para esta regla
        FOR condition_record IN 
            SELECT * FROM rule_conditions 
            WHERE rule_id = rule_record.rule_id 
            AND table_name = 'user_details'
        LOOP
            -- Inicializar como falsa la condición (se verifica a continuación)
            condition_met := FALSE;
            
            -- Evaluar la condición usando el operador correspondiente (>=, <=, ==, etc.)
            CASE condition_record.operator
                WHEN '>=' THEN
                    condition_met := (user_data->>condition_record.column_name)::NUMERIC >= condition_record.value_numeric;
                WHEN '<=' THEN
                    condition_met := (user_data->>condition_record.column_name)::NUMERIC <= condition_record.value_numeric;
                WHEN '>' THEN
                    condition_met := (user_data->>condition_record.column_name)::NUMERIC > condition_record.value_numeric;
                WHEN '<' THEN
                    condition_met := (user_data->>condition_record.column_name)::NUMERIC < condition_record.value_numeric;
                WHEN '==' THEN
                    IF condition_record.value_numeric IS NOT NULL THEN
                        -- Comparación numérica exacta
                        condition_met := (user_data->>condition_record.column_name)::NUMERIC = condition_record.value_numeric;
                    ELSE
                        -- Comparación de texto exacta
                        condition_met := (user_data->>condition_record.column_name) = condition_record.value_text;
                    END IF;
                WHEN '!=' THEN
                    IF condition_record.value_numeric IS NOT NULL THEN
                        -- Comparación numérica de desigualdad
                        condition_met := (user_data->>condition_record.column_name)::NUMERIC != condition_record.value_numeric;
                    ELSE
                        -- Comparación de texto de desigualdad
                        condition_met := (user_data->>condition_record.column_name) != condition_record.value_text;
                    END IF;
            END CASE;
            
            -- Si alguna condición no se cumple para el usuario, marcar como falso y salir del loop
            IF NOT condition_met THEN
                user_conditions_met := FALSE;
                EXIT;
            END IF;
        END LOOP;
        
        -- Si el usuario no cumple las condiciones, pasar a la siguiente regla
        IF NOT user_conditions_met THEN
            CONTINUE;
        END IF;
        
        -- Verificar condiciones que aplican a cada anime en la lista, para esta regla
        FOR anime_item IN SELECT * FROM jsonb_array_elements(anime_list)
        LOOP
            -- Inicializar variable que indica si el anime cumple todas las condiciones para esta regla
            anime_conditions_met := TRUE;
            
            -- Revisar todas las condiciones de anime para esta regla
            FOR condition_record IN 
                SELECT * FROM rule_conditions 
                WHERE rule_id = rule_record.rule_id 
                AND table_name = 'anime_dataset'
            LOOP
                -- Inicializar condición como falsa para evaluación
                condition_met := FALSE;
                
                -- Evaluar condición según operador
                CASE condition_record.operator
                    WHEN '>=' THEN
                        condition_met := (anime_item->>condition_record.column_name)::NUMERIC >= condition_record.value_numeric;
                    WHEN '<=' THEN
                        condition_met := (anime_item->>condition_record.column_name)::NUMERIC <= condition_record.value_numeric;
                    WHEN '>' THEN
                        condition_met := (anime_item->>condition_record.column_name)::NUMERIC > condition_record.value_numeric;
                    WHEN '<' THEN
                        condition_met := (anime_item->>condition_record.column_name)::NUMERIC < condition_record.value_numeric;
                    WHEN '==' THEN
                        IF condition_record.value_numeric IS NOT NULL THEN
                            -- Comparación numérica exacta
                            condition_met := (anime_item->>condition_record.column_name)::NUMERIC = condition_record.value_numeric;
                        ELSE
                            -- Para columnas que son arrays JSON (genres, keywords, producers), verificar si el valor está presente
                            IF condition_record.column_name IN ('genres', 'keywords', 'producers') THEN
                                SELECT bool_or(elem::text = quote_literal(condition_record.value_text)) INTO array_check_result
                                FROM jsonb_array_elements_text(anime_item->condition_record.column_name) elem;
                                condition_met := COALESCE(array_check_result, FALSE);
                            ELSE
                                -- Comparación exacta de texto para columnas simples
                                condition_met := (anime_item->>condition_record.column_name) = condition_record.value_text;
                            END IF;
                        END IF;
                    WHEN '!=' THEN
                        IF condition_record.value_numeric IS NOT NULL THEN
                            -- Comparación numérica de desigualdad
                            condition_met := (anime_item->>condition_record.column_name)::NUMERIC != condition_record.value_numeric;
                        ELSE
                            -- Para arrays, verificar que el valor NO esté presente
                            IF condition_record.column_name IN ('genres', 'keywords', 'producers') THEN
                                SELECT bool_or(elem::text = quote_literal(condition_record.value_text)) INTO array_check_result
                                FROM jsonb_array_elements_text(anime_item->condition_record.column_name) elem;
                                condition_met := NOT COALESCE(array_check_result, FALSE);
                            ELSE
                                -- Comparación de texto de desigualdad para columnas simples
                                condition_met := (anime_item->>condition_record.column_name) != condition_record.value_text;
                            END IF;
                        END IF;
                END CASE;
                
                -- Si alguna condición de anime no se cumple, marcar como falso y salir del loop
                IF NOT condition_met THEN
                    anime_conditions_met := FALSE;
                    EXIT;
                END IF;
            END LOOP;
            
            -- Si el anime cumple todas las condiciones, insertar en tabla temporal de resultados
            IF anime_conditions_met THEN
                temp_anime_id := (anime_item->>'anime_id')::INT;
                -- Se usa nombre en inglés si está disponible, sino nombre original
                temp_anime_name := COALESCE(anime_item->>'english_name', anime_item->>'name');
                
                INSERT INTO temp_results (anime_id, nombre) 
                VALUES (temp_anime_id, temp_anime_name);
            END IF;
        END LOOP;
    END LOOP;
    
    -- Retornar los resultados agrupados por anime con el conteo de cuántas veces cumplen reglas
    RETURN QUERY
    SELECT 
        tr.anime_id,
        tr.nombre,
        COUNT(*)::INTEGER as cantidad
    FROM temp_results tr
    GROUP BY tr.anime_id, tr.nombre
    ORDER BY cantidad DESC, tr.anime_id;
    
END;
$$ LANGUAGE plpgsql;

--
-- PostgreSQL database dump
--

-- Dumped from database version 17.4
-- Dumped by pg_dump version 17.4

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Data for Name: anime_dataset; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.anime_dataset (anime_id, name, score, genres, keywords, type, episodes, aired, premiered, status, producers, studios, source, rating, rank, popularity, favorites, scored_by, members, duration_class, episodes_class) FROM stdin;
28951	Beluga	4.50	{"Avant Garde",Horror}	{"little match girl \\".","horror spin","classic tale"}	Movie	1	2011	\N	Finished Airing	{}	\N	Book	R+ - Mild Nudity	14061	13264	1	711	1457	short	short
28953	Sougiya to Inu	4.99	{"Avant Garde",Horror}	{"snow white","horror take","classic tale"}	Movie	1	2010	\N	Finished Airing	{}	\N	Unknown	G - All Ages	13621	14540	0	468	1047	short	short
28955	Columbos	4.77	{Drama,Mystery}	{"puppet animation",imagining,columbo}	Movie	1	2012	\N	Finished Airing	{}	\N	Other	PG-13 - Teens 13 or older	13850	16977	0	258	572	short	short
28957	Mushishi Zoku Shou: Suzu no Shizuku	8.58	{Adventure,Mystery,"Slice of Life",Supernatural}	{"enigmatic girl called kaya","warm summer day","shizuku follows ginko","several years later","peculiar journey amidst","mushishi zoku shou","mushishi ginko encounters","ginko coincidentally runs","ginko soon begins","strange girl","mysterious girl","weeds growing","mystery behind","mal rewrite","last arc","boy heard","bells ringing","boy yoshiro","mountain near",soon,yoshiro,mountain,mountain,mountain,written,way,unravel,uncover,suzu,sound,occult,manga,home,home,help,happened,grown,celebration,body,become,adaptation}	Movie	1	2015	\N	Finished Airing	{Aniplex,Kodansha,"Delfi Sound"}	Artland	Manga	PG-13 - Teens 13 or older	110	1817	235	54763	137729	long	short
28959	Kizuna (Special)	5.74	{Drama,Romance}	{"short animation",tekken}	Special	1	2012	\N	Finished Airing	{}	\N	Original	G - All Ages	11472	14771	2	527	982	short	short
28961	Idol☆Sister	7.07	{Hentai}	{"new group called platinum kiss","idol group ikb31","success onstage would","one hour left","perverted nature","older brother","next concert","nerves ”.","mal rewrite","maki kamii","maina ooizumi","former members","every action","desperate effort","biggest reasons","ayaka takano",one,ayaka,written,turns,performance,peeping,might,manager,informs,helps,girls,girls,form,find,feel,despite,day,causing,calming,attend,anxious,able}	OVA	1	2014	\N	Finished Airing	{"Union Cho"}	Silver	Manga	Rx - Hentai	\N	5496	112	8310	18108	long	short
28963	Nekota no Koto ga Kininatte Shikatanai.	5.97	{}	{"ribon festa 2015 event","koto ga kininatte shikatanai","girl named mikiko sees","popular boy","manga screened","anime adaptation",nekota,face,face,class,cat}	Special	1	2015	\N	Finished Airing	{}	\N	Manga	G - All Ages	10327	13254	2	394	1466	short	short
28965	Kibun wa Uaa Jitsuzai OL Kouza	\N	{Comedy}	{"quite frequent","head —","emotional disbelief","office lady",office,uaa,town,state,situations,phrase,friends,follows,expresses,dating}	OVA	1	1994	\N	Finished Airing	{"Group TAC"}	\N	Unknown	PG-13 - Teens 13 or older	17547	20543	0	\N	296	long	short
28977	Gintama°	9.05	{Action,Comedy,Sci-Fi}	{"gintoki drunkenly staggers home one night","fatally injured crew member emerges","fourth season finds gintoki","alien spaceship crashes nearby","dangerous crises yet","chan really spend","cash playing pachinko","gives gintoki","gintoki proceeds","alien overlords","yorozuya team","yorozuya team","world outside","whatever work","suddenly discovers","reality edo","paid ...","next morning","mal rewrite","incredibly powerful","hilarious misadventures","heartfelt emotion","friends facing","conquered japan","cheek humor","broke members","shaped device","kagura still","kagura return","device fixed","alarm clock",gintoki,kagura,device,clock,written,warning,usual,try,tongue,thrive,though,swords,strange,standstill,smash,simple,side,ship,shinpachi,shinpachi,shinpachi,sets,safeguarded,prohibited,nothing,must,moments,mistaking,meanwhile,loving,living,however,hands,gintama,gin,get,get,fun,filled,ever,come,apartment,alternate}	TV	51	2015	spring	Finished Airing	{"TV Tokyo",Aniplex,Dentsu}	Bandai Namco Pictures	Manga	PG-13 - Teens 13 or older	6	343	17287	266236	674806	standard	long
28979	To LOVE-Ru Darkness 2nd	7.42	{Comedy,Romance,Sci-Fi,Ecchi}	{"transforming assassin golden darkness returns","previously estranged family quickly becomes","evil force looms amidst","shaky ground amidst rito","younger sister mea","sinister nemesis manipulates","newly discovered mother","longtime crush haruna","harem plan stands","princess momo","peer deeper","new life","mysteries surrounding","mal rewrite","innocuous commotion","grown feelings",rito,harem,written,threatening,things,tearju,shadows,shadow,seem,peaceful,love,love,light,inability,hope,happiness,hand,friendship,everyone,eclipse,dispassionate,confess,center,banish,attention,along}	TV	12	2015	summer	Finished Airing	{TBS,"Magic Capsule","Warner Bros. Japan","NBCUniversal Entertainment Japan",Shueisha}	Xebec	Manga	R+ - Mild Nudity	2345	983	967	142454	272882	standard	medium
28981	Ame-iro Cocoa	4.73	{"Slice of Life"}	{"two handsome college students start frequenting","girlish good looks","barista shion koga","aoi cannot help","diverse cafe known","aoi tokura","aoi serves","small crowd","rainy color","mal rewrite","hot cocoa",cafe,written,well,server,regulars,lives,drawn,cozy,attracted,along}	TV	12	2015	spring	Finished Airing	{"DAX Production"}	EMT Squared	Web manga	PG-13 - Teens 13 or older	13895	4559	12	11937	28578	short	medium
28983	Bouken-tachi Gamba to Nanbiki no Nakama	5.86	{Adventure}	{"guy gamba rashly promises","badly injured mouse staggers","evil white weasel","help depose noroi","tokyo harbor","anime encyclopedia","local mice",noroi,mice,tough,terror,tells,source,ship,reign,island,escaped,devil,crushed}	Movie	1	1984	\N	Finished Airing	{}	Tokyo Movie Shinsha	Novel	G - All Ages	10922	16820	0	141	590	long	short
28987	Kamakura	5.33	{"Avant Garde"}	{"snowy hut melts","berlinale 2014 programme","rice field","covered house","space –",space,white,time,state,spring,source,snow,situated,quietude,one,middle,loses,japanese,haiku,appearance,animation}	Movie	1	2013	\N	Finished Airing	{}	\N	Original	G - All Ages	12968	17166	0	251	551	short	short
28989	Maku	5.29	{"Avant Garde"}	{"yoriko mizushiri","two people","start groping","sound bliss","practice immediately","pair keeps","busily pick","comfortable feelings",feelings,feelings,feelings,feelings,try,track,tender,space,source,somehow,sense,reconstruct,put,partners,life,find,fearful,fascinate,face,distance,connect,body,blend,appreciate,animation,".\\""}	Movie	1	2014	\N	Finished Airing	{}	\N	Original	G - All Ages	13069	16590	0	254	620	short	short
28991	Ninja & Soldier	5.72	{}	{"naïve game addresses cruel realities","old boys compete","two eight","film explores","contrasting graphics","childish bravado","child soldier",game,year,types,talk,source,nito,ninja,mother,kill,ken,humankind,forced,differences,congo,common,capable,berlinale,acts,accompanied}	Movie	1	2012	\N	Finished Airing	{}	\N	Unknown	G - All Ages	11611	16973	0	242	573	short	short
28993	Hand Soap	4.39	{"Avant Garde"}	{"family life","dark vision",atmospheric,adolescence}	Movie	1	2008	\N	Finished Airing	{}	\N	Original	R+ - Mild Nudity	14101	13999	1	555	1201	short	short
28999	Charlotte	7.75	{Drama}	{"protect new ability users","ordinary high school student","headstrong student council president","possess supernatural abilities —","prestigious high school","nao tomori —","student council serving","mysterious power allowed","could ever imagine","yuu otosaka would","yuu begrudgingly assisting","nao convinces yuu","hoshinoumi academy —","student council","council affairs","hoshinoumi academy","mal rewrite","institution created","group sets","five seconds","findings entangle","eventually stopped","dishonest acts","complicated matters",yuu,ability,abilities,hoshinoumi,written,way,transfer,top,time,though,take,shenanigans,sees,secretly,powers,people,mind,means,locating,lasts,join,investigate,however,harm,find,far,enter,deceit,continues,coercion,class,cheat,body,adolescents,abuse}	TV	13	2015	summer	Finished Airing	{Aniplex,"Mainichi Broadcasting System",Movic,"Visual Arts","ASCII Media Works","Tokyo MX",BS11}	P.A. Works	Original	PG-13 - Teens 13 or older	1204	66	24571	1041447	1716551	standard	medium
29003	Lena Lena	\N	{"Slice of Life"}	{"world like children","incredibly curious girl","harriët van reek","explores whatever comes","picture book","lena lena",worm,way,rat,looks,even,body,based,adventures}	TV	13	2009	summer	Finished Airing	{"Sony Music Entertainment"}	\N	Picture book	G - All Ages	17926	18151	0	\N	461	short	medium
29017	Wooser no Sono Higurashi: Mugen-hen	6.51	{Comedy,Fantasy,"Slice of Life"}	{"crude wooser returns","wooser ’","three things","phantasmagoric arc","another season","mouth life",wooser,life,zany,source,money,meat,hand,girls,edited,cute,crunchyroll,creature,cares}	TV	13	2015	summer	Finished Airing	{}	SANZIGEN	Web manga	G - All Ages	7207	9035	4	2276	5237	short	medium
29027	Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou	6.90	{Action,Supernatural,Ecchi}	{"new prototype succubus video camera","ususal hijinx using","shinmai maou","record one","ova episode","light novel","hasegawa sensei","ever would","erotic dreams","eight volume","part b",part,tries,testament,sold,property,mio,maria,invited,hospitality,gets,expected,dinner,basara,apartment}	OVA	1	2015	\N	Finished Airing	{}	Production IMS	Light novel	R+ - Mild Nudity	4957	1867	112	69229	134295	long	short
29035	Robot Girls Z Plus	6.29	{Comedy}	{"great mazinger tai getter robo g","great mazinger tai getter robo","new robot girls z anime","robot girls z +","great space encounter ).","getter robo g","great mazinger vs","great mazinger vs","reformed team g","toei manga matsuri","debut next spring","based two classic","six monthly shorts","getter robo","team z","new shorts","new shorts","team lod","team gou","online game","kuuchuu dai","first appeared",story,source,protagonists,gekitotsu,franchise,films,characters,appear,ann,along}	ONA	6	2015	\N	Finished Airing	{"Nippon Columbia","LandQ studios"}	Toei Animation	Original	PG-13 - Teens 13 or older	8490	7692	2	3537	7804	short	short
29053	Orangutan	4.91	{}	{"jim rock singers","yasunori soryo","uta program","music video",song,nhk,minna,featured}	Music	1	1980	\N	Finished Airing	{NHK}	\N	Original	G - All Ages	\N	18592	0	193	429	short	short
29067	Danna ga Nani wo Itteiru ka Wakaranai Ken 2 Sure-me	7.30	{Comedy,Romance}	{"workaholic office lady kaoru still get","hilarious situations thanks","hardcore otaku shut","best foot forward","hajime works harder","kaoru reflects","worthy father","tsunashi couple","selfless love","marriage —","mal rewrite","good husband","friends surrounding","eccentric natures","bizarre group",kaoru,hajime,written,two,tribulations,trials,sake,remembers,relationship,put,pregnancy,offbeat,meanwhile,long,lives,lively,learning,lasting,ever,ever,continue,closer,brought,become}	TV	13	2015	spring	Finished Airing	{"DAX Production","Dream Creation"}	Seven	4-koma manga	PG-13 - Teens 13 or older	2918	1287	189	124188	207098	short	medium
29073	Tottori U-turn	4.75	{Sports}	{"ad points viewers towards","swimmer leaves tottori","job placement agency","tottori u","home prefecture",job,video,turn,source,return,process,find,compete,ann,aid}	CM	1	2014	\N	Finished Airing	{}	\N	Original	G - All Ages	\N	18057	0	205	467	short	short
29083	Lovely x Cation The Animation	7.21	{Hentai}	{"one spring day","carefree school life","protagonist lives alone","still young","stand seeing","find love","apartment owned",lives,uncle,uncle,tells,room,interested,however,go,girls,experience,confining,anyone}	OVA	2	2015	\N	Finished Airing	{"Pink Pineapple"}	T-Rex	Visual novel	Rx - Hentai	\N	6356	40	4542	12449	long	short
29085	Sei Yariman Sisters Pakopako Nikki The Animation	6.81	{Hentai}	{"five years kenta returns","kenta quickly learns","adult pc game","uncle got transferred","take care","outgoing girls","orc soft","older cousins","nearby school","family lives","another city","twins saki","surprise saki","former house","maki waste",uncle,saki,house,maki,maki,younger,vndb,used,time,three,supposed,stay,source,plans,meet,means,grown,based,attend,approach,aggressivly}	OVA	1	2015	\N	Finished Airing	{"Pink Pineapple"}	G-Lam	Visual novel	Rx - Hentai	\N	6845	37	4078	10416	long	short
29087	Wangpai Yushi	6.52	{Comedy,Fantasy,Supernatural}	{"‘ untamed ’ monsters","monsters learn","joyful story","hardworking censorates","eih scans","day merged",yin,yang,world,source,night,lost,humans,fight,coexist,best,balance}	ONA	39	2014	\N	Finished Airing	{"Tencent Animation & Comics","LAN Studio"}	Haoliners Animation League	Manga	PG-13 - Teens 13 or older	7113	10098	11	712	3777	short	long
29089	Yaoguai Mingdan	6.80	{Action,Comedy,Fantasy,Romance}	{"hero feng xi must fight","strange misty tree demon","goddess xianjia","foxy temptress","eih scans",world,women,source,save,protect,power,peace,order,girl,feat,caught}	ONA	18	2014	\N	Finished Airing	{"Tencent Animation & Comics",iQIYI}	Haoliners Animation League	Web manga	PG-13 - Teens 13 or older	5454	4655	51	5349	27320	short	medium
29093	Grisaia no Meikyuu: Caprice no Mayu 0	7.81	{Drama}	{"perhaps broken — yuuji","thoroughly examine yuuji","attended mihama academy","formed —","yuuji kazami","mihama uncover","suddenly decides","seemingly found","place within","past begin","mal rewrite","darkness ...","consulting jb","torn documents",yuuji,documents,year,written,upbringing,unbeknownst,two,today,thought,story,school,room,restoring,pursue,promotion,present,papers,meanwhile,man,job,intentions,however,history,haunted,girls,fit,events,drag,dissect,discover,determine,cirs,chains,back}	TV Special	1	2015	\N	Finished Airing	{"Frontier Works","Magic Capsule","NBCUniversal Entertainment Japan","Front Wing"}	8bit	Visual novel	R+ - Mild Nudity	1060	1052	723	153957	255043	long	short
29095	Grisaia no Rakuen	7.73	{Drama,Romance,Suspense}	{"video showing apparently concrete proof","ichigaya knows full well","rakuen begins right","mysterious new figure","extremely devastating weapon","assassinate heath oslo","terrorist organization","previous installment","political gain","mihama academy","yuuji committed","yuuji ...","let yuuji","kazami yuuji","neither may",ichigaya,ichigaya,yuuji,yuuji,may,used,terrorism,suspicion,possession,plans,meikyuu,lost,leader,held,grisaia,grisaia,girls,fail,fact,end,custody,crimes,commit,arrested,appears,acts,accused}	TV	10	2015	spring	Finished Airing	{"Frontier Works",AT-X,"Magic Capsule",Bushiroad,"NBCUniversal Entertainment Japan",i0+,"Front Wing"}	8bit	Visual novel	R - 17+ (violence & profanity)	1258	590	2067	230143	430652	standard	short
29099	Washimo 2nd Season	\N	{Comedy,Sci-Fi,"Slice of Life"}	{"washimo series","second season"}	TV	24	2015	winter	Finished Airing	{NHK}	Studio Deen	Picture book	G - All Ages	15836	18119	0	\N	463	short	long
29101	Grisaia no Kajitsu Specials	6.89	{Ecchi}	{"short specials added","dvd volumes",ray,blu}	Special	6	2014	\N	Finished Airing	{}	8bit	Visual novel	R+ - Mild Nudity	4992	2537	60	45142	85469	short	short
29103	Tanoshii Sansuu	5.08	{}	{"nhk tokyo children","uta program","seiji tanaka","music video",nhk,song,part,minna,choir,arithmetic,aired}	Music	1	1988	\N	Finished Airing	{NHK}	\N	Original	G - All Ages	\N	19433	0	177	363	short	short
29105	Aruite Mikka!	4.20	{Comedy}	{"short cgi music video","george tokoro featured","uta program",nhk,minna}	Music	1	1999	\N	Finished Airing	{NHK}	Polygon Pictures	Original	G - All Ages	\N	15782	0	407	742	short	short
29107	Banana Mura ni Ame ga Furu	4.75	{}	{"music video featured","uta program",nhk,minna}	Music	1	1987	\N	Finished Airing	{NHK}	\N	Original	G - All Ages	\N	17106	0	280	557	short	short
29111	Onna Spy Goumon: Teki no Ajito wa Jotai Goumonsho	4.77	{Hentai}	{}	OVA	1	2001	\N	Finished Airing	{}	\N	Unknown	Rx - Hentai	\N	16009	1	200	707	long	short
29123	World Calling	6.11	{}	{"ia x jin project","music video"}	Music	1	2012	\N	Finished Airing	{}	\N	Mixed media	G - All Ages	\N	12132	4	1156	2079	short	short
29129	Ookami Shoujo to Kuro Ouji Recap	6.80	{Comedy,Romance}	{"kuro ouji tv series","ookami shoujo",recap}	TV Special	1	2014	\N	Finished Airing	{VAP}	TYO Animations	Manga	PG-13 - Teens 13 or older	5491	5513	26	6885	17953	standard	short
\.


--
-- Data for Name: rules; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rules (rule_id, target_value) FROM stdin;
e4f0488b-b58d-4f42-875c-8240f6b0838d	28957
b21a5c07-d976-4338-8f7d-2d6e91954c25	28957
08406a0f-d1fb-476e-808e-b0f0bb409fce	28957
090ab6ef-d189-4419-a6ea-28e873316245	28957
671ededd-f7ac-497a-8725-5430de21dbbd	28957
11ed7fad-ad9c-4f72-9eec-b79f710d079f	28957
a083325e-cac1-42aa-8a24-cb90e4adc156	28957
22d95ea2-4fe2-4115-85ee-2e1922e49837	28957
95662418-9542-4a60-8912-eda3ac2ac4b3	28957
cbc5362c-b29d-40b1-b124-852c7cd6aa4d	28957
12aa2c8f-c771-4300-ba53-f37dff243712	28957
dabd3517-49af-4f04-90f7-884a9f799854	28957
76e5791a-8d19-4d67-bd7e-62f47413bcf2	28957
054c691f-0e6e-41d3-a322-04034836ce1f	28957
475f6397-e14d-48bd-b593-e690dc5fe4fa	28957
21776b7a-c45e-4269-85ac-1019e85bfec5	28957
a7cc1e1d-635c-4207-a300-695a70fefc7c	28957
a6a20b4a-b88b-4c77-aa51-06802e8a3abb	28957
32c124df-6b01-4e3f-934b-14a019daa9f8	28957
151863d5-a43b-4c8a-bab2-ec0ab148dcc6	28957
92faa55a-038a-42b8-9217-3abe7e8fd1e3	28957
1882657c-68f8-47c4-9178-13541bd8ce65	28957
3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	28957
7285f2b8-ef82-4eff-a662-38a0f6a0915a	28957
d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	28957
59e71238-88c9-4993-8def-3806d5cbbd2f	28957
b3907655-7605-4dcd-9efc-62ac5be5e16d	28957
8dbf69bc-04f2-424d-85cf-af67599ee0a7	28957
a82b6472-9ea2-430c-b7c3-45965078227c	28957
eb310f6f-dfa3-4194-96b0-d3945a9a660d	28999
8a6a9cb6-1ea8-4941-aa4a-831e175c0538	28999
fe22dad7-1104-4d3a-bd48-079248abe538	28999
1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	28999
abce6278-27a7-471d-b748-bb53bb639e6b	28999
fe3b28c4-9c30-4666-b8be-e3d32f40b17f	28999
4afb6eff-02eb-4883-b27a-60d9e10de775	28999
9d0f46ac-bfbf-41fd-96d6-b113512f15ea	28999
925e8fe4-5e18-4383-9c6b-8e24bb010186	28999
3e7bf968-36ea-4ad5-8ef8-564cd8276af5	28999
ac14e32d-e9d4-40a7-a246-fb0680cc273c	28999
3c501a42-adf9-41c5-8fb6-910d5ff50db6	28999
5c100995-3313-4b0f-b374-212adde68ddf	28999
8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	28999
3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	28999
22848b98-19e4-426c-9991-267149693761	28999
6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	28999
923c8b80-0dfe-46c5-89bb-123a6e47dd93	28999
b310581d-6be8-46a8-9ae5-11358d098e5c	28999
ae497e26-2f77-45b7-b44a-85dd3863f584	28999
208baf0c-968c-4706-be00-f504343e2515	28999
4af59c30-f7a0-4493-8d54-510de2d052c1	28999
686964a0-61c2-4f1b-98fc-e434a160065d	28999
2a2e4973-2e9d-459c-b549-39a63635a70d	28999
b4a05236-5978-4b62-984a-cc6fc8929ff9	28999
7fb53324-c0dc-4542-92f8-972fd8aaea8d	28999
2d85cda3-989c-41e8-8d76-ff7a37d0a27d	28999
828e4feb-64c3-4de2-8100-65921b2d8f6a	28999
a0af810a-1708-4c51-9e9f-00536fa77eb0	28999
b9e02233-4865-42b4-ad3a-f70a6c218fe5	28999
8e857d45-a82e-4fc6-ab2e-77e97d0ab743	28999
f0ab426b-97a2-4b38-9126-f92fc1380e97	28999
44089aad-3502-4ac5-9a39-a5be29a27ec5	28999
442ce7d7-5851-4576-af61-0adf82b67404	28999
df871e48-2c98-4916-b770-d089f8eb83d8	28999
ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	28999
1f8c64e4-2ced-49fc-8b61-42184624d2ed	28999
c5820446-f6a2-424a-9cc1-9221395c27f9	28999
997e80d9-0767-4204-bc4e-5247b2bc34b5	28999
59f652b2-62e2-473a-ada0-fb577819c17c	28999
d9690601-00bb-4de3-9542-b7bb0e10d857	28999
\.


--
-- Data for Name: rule_conditions; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.rule_conditions (condition_id, rule_id, table_name, column_name, operator, value_text, value_numeric) FROM stdin;
01089c75-8eb7-4f64-bfae-0c3f00be9bef	e4f0488b-b58d-4f42-875c-8240f6b0838d	user_details	rewatched	>=	\N	0.0
cdc01faa-9ef4-452d-8f7e-76f05849dd91	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	episodes	>=	\N	1.0
d7c24607-c46f-4c74-a0d4-3b9684c7a251	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	scored_by	>=	\N	54763.0
87090650-380b-4222-a10b-16a7f32f1839	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	status	==	Finished Airing	\N
a26789fc-becb-462b-9384-2b4b07b0dd5d	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	favorites	>=	\N	235.0
670100b6-5933-438e-801c-080bb00b8290	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	genres	==	Supernatural	\N
87a3dc43-4cbd-48cd-9844-464736ddc40d	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	producers	==	Kodansha	\N
be7e2ba3-5a1c-465a-97c7-af635bceb6fe	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	rank	>=	\N	110.0
8aadb99a-6211-4227-bfb5-38f4a8fcc523	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	keywords	==	strange girl	\N
b05c684d-bc38-4223-a46c-862a5b793476	e4f0488b-b58d-4f42-875c-8240f6b0838d	anime_dataset	duration_class	==	long	\N
1ace665a-bc6b-4367-b15a-4134d16d354f	b21a5c07-d976-4338-8f7d-2d6e91954c25	user_details	rewatched	>=	\N	0.0
43e1b3b3-2a8d-47f0-86fc-2222f42219cc	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	rank	>=	\N	110.0
94fb0ac0-b055-4ed5-a3d5-dce475f14738	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	studios	==	Artland	\N
ec8f0380-9e09-4715-913d-8eafd3c2c05e	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	popularity	>=	\N	1817.0
7b24bcd0-e859-4d2a-b46e-0a1616a304a3	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	status	==	Finished Airing	\N
ae9aa0bd-2eef-462f-a479-6a629d993036	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	genres	==	Supernatural	\N
f7bdfdb2-277c-46ec-bf2e-f040ce4caa33	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	episodes_class	==	short	\N
57fa3747-36f8-4f0e-a7db-8ebda2b8c6bb	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	duration_class	==	long	\N
cb936622-8b92-413e-9c2c-9581721152a3	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	score	>=	\N	8.58
4792bf2a-5052-4b6d-ac7d-b96826af3de0	b21a5c07-d976-4338-8f7d-2d6e91954c25	anime_dataset	members	>=	\N	137729.0
e4afaffe-ea80-4d5d-9eff-7cff1d339051	08406a0f-d1fb-476e-808e-b0f0bb409fce	user_details	rewatched	>=	\N	0.0
78593589-751d-4f5e-aa2e-6ef4965d523d	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	rank	>=	\N	110.0
4b61d166-22ee-48ec-bb5d-5b9eb1096181	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	studios	==	Artland	\N
c381b26f-14f1-4447-a57d-070c9a0fd296	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	popularity	>=	\N	1817.0
2a7d05fd-df50-42ae-a16a-55b7add172d5	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	status	==	Finished Airing	\N
2d1768c4-6b38-447a-85ec-80a15514de3b	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	genres	==	Supernatural	\N
5a40a0df-c181-42ca-81b4-dc552bec4e99	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	episodes_class	==	short	\N
410c584b-b680-4d23-acc7-eb5d207c0bb5	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	duration_class	==	long	\N
f5962022-e66c-40fe-a168-3ae988f83e9c	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	score	>=	\N	8.58
64dc00e5-1099-4b48-905b-8dd771aad335	08406a0f-d1fb-476e-808e-b0f0bb409fce	anime_dataset	source	==	Manga	\N
893acffd-7e8b-4100-8069-c01b98c5ceef	090ab6ef-d189-4419-a6ea-28e873316245	user_details	rewatched	>=	\N	0.0
3391d39d-fc42-40cf-b9a4-b64436a22bb6	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	episodes	>=	\N	1.0
a6e6e18d-7c4f-413f-84ce-466195ee2ae3	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	keywords	==	strange girl	\N
4a858ab5-9eea-4766-9bcc-8b65331c5f95	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	rank	>=	\N	110.0
eee50f78-df77-4650-a0ef-2551cbf0a8b1	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	producers	==	Aniplex	\N
b5424da6-b131-453d-a301-a5b08ae9f78b	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	genres	==	Supernatural	\N
6d7f0b35-c22c-41ea-ba3f-59b163cbfd32	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	favorites	>=	\N	235.0
2acf5fa6-1036-44bb-800b-b61ad654a351	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	score	>=	\N	8.58
cd03cc2e-7a8c-48fd-acd5-b874b900076b	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	source	==	Manga	\N
b3ee9430-03ba-4373-906c-ad7ca53aa8f6	090ab6ef-d189-4419-a6ea-28e873316245	anime_dataset	members	>=	\N	137729.0
47d738fb-23c2-43e7-aa24-a45898dd03eb	671ededd-f7ac-497a-8725-5430de21dbbd	user_details	rewatched	>=	\N	0.0
d2854651-96da-4642-96bc-2b64c0b33963	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	duration_class	==	long	\N
9754c7e5-c3db-42cf-b13b-56cba2c57a82	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	keywords	==	strange girl	\N
67dd89e5-56cc-4541-8d6b-ce3817e58b49	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	popularity	>=	\N	1817.0
340eeaf0-4e68-42ec-817c-66986e151347	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	status	==	Finished Airing	\N
17974c18-7460-4672-9622-5bef90ac1fd5	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	genres	==	Supernatural	\N
bbd44736-bfe5-48c9-a7f4-00e73c13e7e1	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	favorites	>=	\N	235.0
64f6a787-b512-4834-b2cb-f0cdd96388ab	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	source	==	Manga	\N
37216b24-1bde-43d0-b0fd-8af954d45ebc	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	producers	==	Kodansha	\N
5bfe8a45-29f6-42b2-97a8-e86c62fe2296	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	aired	>=	\N	2015.0
4053fab8-c767-48e4-b271-67bd8e5b984b	671ededd-f7ac-497a-8725-5430de21dbbd	anime_dataset	type	==	Movie	\N
151a7b46-8d6c-4499-8b94-1bbecc058ff3	11ed7fad-ad9c-4f72-9eec-b79f710d079f	user_details	rewatched	>=	\N	0.0
61297d35-e2aa-4656-a55f-e649715135ce	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	episodes	>=	\N	1.0
b33aab68-0cbc-4d72-b9b8-c08cffbbd2a4	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	scored_by	>=	\N	54763.0
3c025993-ef66-4f13-b329-c8a8d553eda4	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	status	==	Finished Airing	\N
ccd73311-8d12-4e35-b262-080e0c73ba40	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	producers	==	Kodansha	\N
2f4b4a4d-f662-4561-b1d2-69ddb835a4d7	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	genres	==	Supernatural	\N
d7076fcc-ca50-42f1-9288-c8c37195638c	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	episodes_class	==	short	\N
f85a5dd7-4b48-49c3-9a18-2030081e710d	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	favorites	>=	\N	235.0
db2360f8-d942-4f87-a7cf-9e6ca26963a2	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	keywords	==	strange girl	\N
f82d8779-19d7-4d3d-a2f2-7b52c3eac3d6	11ed7fad-ad9c-4f72-9eec-b79f710d079f	anime_dataset	duration_class	==	long	\N
05f0b176-37da-417f-9c8f-0d60765d1349	a083325e-cac1-42aa-8a24-cb90e4adc156	user_details	rewatched	>=	\N	0.0
7f50cf1b-e02e-4407-86b6-4624fdec46bd	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	members	>=	\N	137729.0
355a546a-c005-42da-a299-75d133750d75	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	scored_by	>=	\N	54763.0
e46ea743-5ede-46d4-bb76-685cdbaae1d4	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	duration_class	==	long	\N
b3aab1f3-4d67-4b50-928d-7ba8bfc0a87b	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	episodes_class	==	short	\N
6c583c91-cdb7-4617-a68d-8559d20640ff	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	favorites	>=	\N	235.0
b981077e-9144-4aeb-827e-0eb763294a46	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	source	==	Manga	\N
e1dce114-6c3a-468e-9a15-53fb439c2d17	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	producers	==	Kodansha	\N
2afc69af-f755-4ba8-aaae-bb88c0e01c2a	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	aired	>=	\N	2015.0
aa6955b6-b63b-4b59-958a-beefd4ec3e30	a083325e-cac1-42aa-8a24-cb90e4adc156	anime_dataset	type	==	Movie	\N
1b5d5db9-56fc-41c6-8ff3-47b011c5376d	22d95ea2-4fe2-4115-85ee-2e1922e49837	user_details	rewatched	>=	\N	0.0
b1d0d429-1c84-4f09-9684-6966bd8e18f2	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	rank	>=	\N	110.0
8d49ea60-bfd0-4ade-bb5c-efe4c6b416b4	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	scored_by	>=	\N	54763.0
6a676a94-d419-4bcf-9367-419745b47bd0	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	duration_class	==	long	\N
600fd7a1-969b-4f10-87b1-b442e33a0426	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	episodes_class	==	short	\N
91c1f85a-1fe1-4f98-836c-4071eb9c5d15	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	genres	==	Supernatural	\N
f61b9b4a-bd7a-4724-882e-1dac38b0defd	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	producers	==	Kodansha	\N
7c6af00d-d134-46d8-893c-d8583ff28f8d	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	status	==	Finished Airing	\N
d85c78ff-b674-487c-830d-2f8243b42c74	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	episodes	>=	\N	1.0
a109c106-f2f7-454a-be55-a96274f16876	22d95ea2-4fe2-4115-85ee-2e1922e49837	anime_dataset	studios	==	Artland	\N
aa868cb1-58d6-419d-98e6-08b7b6d9702e	95662418-9542-4a60-8912-eda3ac2ac4b3	user_details	rewatched	>=	\N	0.0
03ed4dfd-fd10-4b6b-bf0f-491f14fcd825	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	episodes	>=	\N	1.0
3e398c2d-f32b-4ccf-957d-a5a69b564753	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	source	==	Manga	\N
ba478000-c82c-4ba8-b39b-8972e214ec90	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	score	>=	\N	8.58
9c5d9eb8-e6ac-492f-9a32-73f96c24d496	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	favorites	>=	\N	235.0
5fd4e1c8-a4bf-4dea-bf7e-2e08a0afb330	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	genres	==	Supernatural	\N
f4daa880-332d-47d5-911c-676da9f136b7	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	producers	==	Kodansha	\N
7e266253-f8c9-4b20-b5e4-7c253620fa24	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	popularity	>=	\N	1817.0
f7045056-a49b-48bd-8355-c28d40fe8b63	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	studios	==	Artland	\N
b1571958-b2be-4a61-bb05-f149bfe8858c	95662418-9542-4a60-8912-eda3ac2ac4b3	anime_dataset	duration_class	==	long	\N
870eda9f-7db4-4b06-b72a-8d31e5e47890	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	user_details	rewatched	>=	\N	0.0
78afa196-b4e9-4708-a0f3-6a1597b1a7da	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	duration_class	==	long	\N
195c174e-6e01-419e-825d-03a0b713dfa8	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	keywords	==	strange girl	\N
30d965bd-ec4c-4290-a451-a5c6e51bb052	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	rank	>=	\N	110.0
896fccee-68fb-4537-af50-21e25903f92f	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	producers	==	Aniplex	\N
7405a926-9eb2-4d0d-bd1f-71621cbfb7c9	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	genres	==	Supernatural	\N
93dabef3-ae10-4f54-8b0a-73b2a2487acb	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	favorites	>=	\N	235.0
298e2580-402f-42b6-9888-4bd28c0a4ef1	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	score	>=	\N	8.58
80c55cba-8341-4b83-8572-cca17ed21339	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	source	==	Manga	\N
cd693f25-3cea-4f1b-b0b0-c4cd2bd44478	cbc5362c-b29d-40b1-b124-852c7cd6aa4d	anime_dataset	members	>=	\N	137729.0
680d8bfd-3cad-4d7b-b532-209c44ec63b9	12aa2c8f-c771-4300-ba53-f37dff243712	user_details	rewatched	>=	\N	0.0
15d2fce5-1acf-4f63-8027-eea515d90b15	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	rank	>=	\N	110.0
49b901fe-7317-4d35-913d-0ea5d331ca88	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	studios	==	Artland	\N
fcb42b03-f198-432f-9d9f-d020d256acc0	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	popularity	>=	\N	1817.0
c67c93bc-f2d9-49e2-a9d5-b7a44aca50de	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	genres	==	Supernatural	\N
9364405d-31b0-4155-8d65-1abecfce3287	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	favorites	>=	\N	235.0
bd1eddd6-2736-485b-a87b-6d5a5186a01f	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	source	==	Manga	\N
164ee614-560c-44c3-93eb-02589e250e16	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	producers	==	Kodansha	\N
4bf6bf7e-cbae-4f27-9bbf-bb9f87632fed	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	aired	>=	\N	2015.0
4d98e428-ff3c-4b35-9303-caed30ce08c7	12aa2c8f-c771-4300-ba53-f37dff243712	anime_dataset	type	==	Movie	\N
cb1e819c-8292-4246-8193-7696a92c6982	dabd3517-49af-4f04-90f7-884a9f799854	user_details	rewatched	>=	\N	0.0
67ba6bf6-b194-473c-ae3d-73b30043ece2	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	episodes	>=	\N	1.0
be11e645-3432-4c6c-8fc8-4280da04ac60	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	scored_by	>=	\N	54763.0
0ecc7316-7b9a-4bd2-b81d-021c822f91a1	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	status	==	Finished Airing	\N
1a939a39-4fd9-41a4-ae05-a6f991e28ab5	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	favorites	>=	\N	235.0
3807bea2-bd53-45b1-a107-d151e4b254cd	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	episodes_class	==	short	\N
e6a10335-70e1-4dc8-a00e-df9f384dcdd1	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	duration_class	==	long	\N
cdd6fafe-11d5-4573-aa52-07f8003db03b	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	type	==	Movie	\N
601e564f-79ca-4b96-a8ad-f85a75e795d4	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	score	>=	\N	8.58
e9cad33e-dc87-4484-8f98-7697053a6bc0	dabd3517-49af-4f04-90f7-884a9f799854	anime_dataset	popularity	>=	\N	1817.0
52ab7466-7c47-487c-a4ce-4eb53a9e47d3	76e5791a-8d19-4d67-bd7e-62f47413bcf2	user_details	rewatched	>=	\N	0.0
f31a8eb3-6396-4608-bdca-fc602c6b0c3f	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	episodes	>=	\N	1.0
cb731a47-7eba-4153-bc4f-a49c7f399831	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	scored_by	>=	\N	54763.0
cc190bf2-f8b2-4241-8032-7b3fc92e02aa	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	status	==	Finished Airing	\N
95cafba5-6d3c-4b85-8688-0d907c4fe0e5	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	genres	==	Supernatural	\N
44456014-3d93-45f4-a863-39a04572a89d	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	favorites	>=	\N	235.0
8914467d-60e5-4089-b0b5-3b9f911adfc5	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	source	==	Manga	\N
c51d3817-f149-49b6-8236-b8d2e5a326ea	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	producers	==	Kodansha	\N
40f7a5a5-0044-408b-a991-6dd43f1d3587	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	aired	>=	\N	2015.0
faeef993-f4b9-4e66-b581-404803c7a019	76e5791a-8d19-4d67-bd7e-62f47413bcf2	anime_dataset	type	==	Movie	\N
a5a63f68-abbf-4ba1-9cb9-9f95a4d202a9	054c691f-0e6e-41d3-a322-04034836ce1f	user_details	rewatched	>=	\N	0.0
d7a9f551-c5df-47f1-9135-350d992b1adf	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	members	>=	\N	137729.0
0a0f5237-1fb9-4f6c-a076-dc2e3b8f9580	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	source	==	Manga	\N
f1ad732c-33a5-4331-8f68-c7c009ac4345	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	score	>=	\N	8.58
4cde2b49-7f31-4608-966b-0f6d6977a5d5	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	favorites	>=	\N	235.0
1a8ffb40-acc5-4c09-b06a-bc0d9f54689a	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	genres	==	Supernatural	\N
885010b4-e438-4e7d-ab8c-0a1d4b561a2b	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	producers	==	Kodansha	\N
ec061e6f-f88c-4d25-b900-b681c370dd7c	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	popularity	>=	\N	1817.0
4f0e0d45-42ad-428b-a004-f6ea2ec54639	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	episodes	>=	\N	1.0
f0c8fb84-bf49-467f-be7c-c43802f88658	054c691f-0e6e-41d3-a322-04034836ce1f	anime_dataset	keywords	==	strange girl	\N
8bba026c-6a2e-47b7-80ca-b3000e011e3f	475f6397-e14d-48bd-b593-e690dc5fe4fa	user_details	rewatched	>=	\N	0.0
f484ab06-0dde-4527-a415-1a01a4099ac8	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	rank	>=	\N	110.0
f41b0ffb-6f10-46fb-b9c8-5c3a92fc7172	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	studios	==	Artland	\N
e91befef-510b-45b0-bab5-ad41c9398025	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	popularity	>=	\N	1817.0
77c33100-e11b-4a83-a6e0-14f8ba0abe40	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	status	==	Finished Airing	\N
c9e989df-fbcc-46a1-9201-84496c3d74d5	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	genres	==	Supernatural	\N
092da688-9c93-4aae-9c00-c0535e2ea15a	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	episodes_class	==	short	\N
51b8a885-ad77-4319-82f7-3100aa6aa87c	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	duration_class	==	long	\N
7bf38554-0c66-49b3-a38e-fc06799ed653	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	producers	==	Kodansha	\N
585f8a19-60b5-4b60-9e4c-26e35406152c	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	aired	>=	\N	2015.0
12007d69-f50f-44df-b3b7-e7e1295fcf66	475f6397-e14d-48bd-b593-e690dc5fe4fa	anime_dataset	type	==	Movie	\N
e4e6f755-9a8d-420a-9efb-879d973eb8eb	21776b7a-c45e-4269-85ac-1019e85bfec5	user_details	rewatched	>=	\N	0.0
caf0cdfb-9184-4ba1-9a99-0b0cf5199453	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	episodes	>=	\N	1.0
3e2fd1e2-70d7-4ea8-898c-c2291b37cc04	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	scored_by	>=	\N	54763.0
7be8b88c-3b46-4e19-abd1-98089df949a2	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	status	==	Finished Airing	\N
ace3b021-0b3b-4142-a78c-709cb8d9e471	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	episodes_class	==	short	\N
f9932738-1486-4738-9fdf-5bdbbc9be91f	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	favorites	>=	\N	235.0
326c8866-d79b-4c19-9a45-1edbee2a1d6c	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	source	==	Manga	\N
b6267153-aafe-4ade-b835-31ba7291d253	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	producers	==	Kodansha	\N
8e5698b6-4cf5-4f54-97d6-5593aae5a00f	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	aired	>=	\N	2015.0
bfd01c59-6ed3-4e8b-a43e-ff099a1fc743	21776b7a-c45e-4269-85ac-1019e85bfec5	anime_dataset	type	==	Movie	\N
bd60bd3f-5b40-45df-bc52-ed6c1685bc01	a7cc1e1d-635c-4207-a300-695a70fefc7c	user_details	rewatched	>=	\N	0.0
76df88e6-6ccd-4592-ae2d-5272d0cdf871	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	rank	>=	\N	110.0
976d1c9b-138f-4472-837a-1acd4183bc01	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	studios	==	Artland	\N
927854c3-83a6-4588-8266-9ae5b66808ee	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	popularity	>=	\N	1817.0
1bb1882b-8a22-4623-b05a-f86144563f24	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	producers	==	Kodansha	\N
8d1df938-6cfc-46b0-a9c4-4f5ec1086fef	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	genres	==	Supernatural	\N
c12a850f-624e-47ab-a5d1-c387ba57e86e	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	favorites	>=	\N	235.0
3be7342b-bf6c-4e7c-8c63-15d3b1daaf73	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	score	>=	\N	8.58
f94c16b5-6fd3-44d3-9075-7505e23916a9	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	source	==	Manga	\N
c91e9601-387a-480b-a85b-92726ac8cf92	a7cc1e1d-635c-4207-a300-695a70fefc7c	anime_dataset	duration_class	==	long	\N
8d3e6bf8-7ee9-4294-8555-778a1fdb315c	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	user_details	rewatched	>=	\N	0.0
aee63040-b877-44a7-8e77-a69968079ddb	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	members	>=	\N	137729.0
e9018bf7-17c4-42b0-b293-8728937c3177	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	studios	==	Artland	\N
79fb41a3-69ef-4075-962b-817a36ca14d0	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	popularity	>=	\N	1817.0
525d0937-f6d1-4eb6-9984-b2a4b84e53b7	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	genres	==	Supernatural	\N
1d0b569f-097d-4bd5-bedf-86bf0f0cf7b8	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	favorites	>=	\N	235.0
591459c8-c3cc-415b-8905-01ef13abf266	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	source	==	Manga	\N
ef5f8e06-e0ed-4599-887c-75a9a86666b3	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	producers	==	Kodansha	\N
4081f4c7-ae94-4a07-8079-c3bba7e6f6b4	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	aired	>=	\N	2015.0
b1619343-a16c-4dbe-83d1-c0c5026ca0f1	a6a20b4a-b88b-4c77-aa51-06802e8a3abb	anime_dataset	type	==	Movie	\N
4211af79-cd8a-4da1-a980-5770bafee347	32c124df-6b01-4e3f-934b-14a019daa9f8	user_details	rewatched	>=	\N	0.0
9dba416b-f160-485f-982c-7f0dac027465	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	type	==	Movie	\N
2dee9229-57eb-4245-96bd-9b1e44766306	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	aired	>=	\N	2015.0
18ebc5e4-8e12-43d4-b745-d3cd6aac5931	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	producers	==	Kodansha	\N
172f6d30-fa1b-4f1a-8220-a3aaf71af0ef	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	source	==	Manga	\N
0cab6e39-3011-47a1-bddd-e4330a6f5bbf	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	favorites	>=	\N	235.0
650a9ce9-b82b-41f9-acf4-c83bc42d2968	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	status	==	Finished Airing	\N
57317574-cd85-4a84-b6f3-86aaf6bfffb3	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	scored_by	>=	\N	54763.0
3a92f745-665f-4040-905e-a5ec9a392ad8	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	episodes	>=	\N	1.0
d8742690-f56e-44e0-9622-57afad8aa7dc	32c124df-6b01-4e3f-934b-14a019daa9f8	anime_dataset	studios	==	Artland	\N
519ca396-8205-4c87-83ca-47e9598f230a	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	user_details	rewatched	>=	\N	0.0
7eea90e3-af89-4f24-b9b7-1e6a709009f2	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	studios	==	Artland	\N
d5919ee0-bcce-47d0-b844-3fedb5996ccb	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	popularity	>=	\N	1817.0
bb4a32d3-6b32-4284-b00b-294742a31ad7	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	status	==	Finished Airing	\N
531ec548-bcbe-4a4d-8e72-21d4c4adef15	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	genres	==	Supernatural	\N
c48f1904-e0af-4adf-a51a-5f356e776e8e	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	favorites	>=	\N	235.0
a6a4269d-2834-4ab6-9a38-56424e0bcf13	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	source	==	Manga	\N
a515b29b-3cf8-4c6a-a970-c40c51c37314	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	producers	==	Kodansha	\N
9794c086-cd8d-43a6-94df-9754eb6e56df	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	aired	>=	\N	2015.0
5d2c3e2e-e7e4-4187-91db-61b05b7fb237	151863d5-a43b-4c8a-bab2-ec0ab148dcc6	anime_dataset	type	==	Movie	\N
fcb30bb0-9d95-41be-8549-e62acd65d766	92faa55a-038a-42b8-9217-3abe7e8fd1e3	user_details	rewatched	>=	\N	0.0
7d50b4c7-3e5d-4ffb-9b68-d5ae3d8aff57	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	members	>=	\N	137729.0
e88ee73c-3054-4496-b642-3000d7498bde	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	scored_by	>=	\N	54763.0
f18dd730-3a5c-4f12-8726-e64cbc09fe6a	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	duration_class	==	long	\N
39a63606-eaa2-4bf4-8657-673868ca2b7b	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	episodes_class	==	short	\N
100fd5d6-b0f7-42fd-b261-fbd66d280b67	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	genres	==	Supernatural	\N
f83fc642-f297-4997-b549-ecb34630edcc	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	producers	==	Kodansha	\N
24b4abbc-4aa6-4337-b89d-1418c7ab6988	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	status	==	Finished Airing	\N
92483829-61d9-4b82-b6e3-f13b6ce09275	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	episodes	>=	\N	1.0
f6f47ed3-f078-474f-8917-be1332774404	92faa55a-038a-42b8-9217-3abe7e8fd1e3	anime_dataset	studios	==	Artland	\N
01d8d445-ad4d-4bee-8e79-3ff67c55afea	1882657c-68f8-47c4-9178-13541bd8ce65	user_details	rewatched	>=	\N	0.0
20ccb44d-5312-4f19-880e-cf40cc8db889	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	source	==	Manga	\N
de8497c9-b12f-4877-88ca-9f0a3bb1b960	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	score	>=	\N	8.58
6877e594-2f02-455d-8c0b-385ffc97441b	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	favorites	>=	\N	235.0
f10c52b8-f852-44c0-ac9e-a2c6da65e7a9	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	genres	==	Supernatural	\N
953fae87-b40b-475e-916d-2a589bd1a1e8	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	status	==	Finished Airing	\N
8aa671a3-ec17-4514-9a79-c73526884714	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	popularity	>=	\N	1817.0
d8090168-ad12-4e59-9aff-2ca9ad99bba8	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	keywords	==	strange girl	\N
44fd8ec5-b7d4-4147-a87e-ed9795a3cbd7	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	duration_class	==	long	\N
660cf5ab-e0b9-4e28-94a7-06bc0e1aeac7	1882657c-68f8-47c4-9178-13541bd8ce65	anime_dataset	episodes	>=	\N	1.0
7b677345-c353-48ff-9bdb-a52f67d866d5	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	user_details	rewatched	>=	\N	0.0
d76a59a0-314c-44dc-9f7b-4898f21e5ac3	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	episodes	>=	\N	1.0
992b5c4e-22c0-4405-a7dc-eeb0dc90a13a	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	keywords	==	strange girl	\N
3e35a4d9-efc1-4230-9892-0657118ac1de	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	popularity	>=	\N	1817.0
ec4a679f-393b-4f6a-bc87-cc31d660247c	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	status	==	Finished Airing	\N
1be452aa-9053-4be2-937a-1e94898efd07	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	genres	==	Supernatural	\N
99ba45cd-bb75-498e-8d47-742192ff54ee	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	favorites	>=	\N	235.0
6b1c1379-a505-4516-8061-4135471807e3	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	source	==	Manga	\N
41a8aaa1-20ae-45d9-822f-f9b2229719d1	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	producers	==	Kodansha	\N
0be22ccd-d732-4c38-8701-2c65dc4c25d2	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	aired	>=	\N	2015.0
9dce7538-a9a6-44ea-9139-6905746b93aa	3f11bd6e-2f6a-47a1-a101-ee4c98ff8f75	anime_dataset	type	==	Movie	\N
7ac795ad-6b25-4021-9fdc-77329be47a43	7285f2b8-ef82-4eff-a662-38a0f6a0915a	user_details	rewatched	>=	\N	0.0
66a60991-c1d3-48b9-9c3e-8e66c2b836d3	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	episodes	>=	\N	1.0
30da9e27-13b4-4d58-a733-474094ac00ad	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	scored_by	>=	\N	54763.0
50d85407-d74e-4963-9d7b-0a8ae7945ea1	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	status	==	Finished Airing	\N
45082346-5413-4e6f-8503-9343569b62f6	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	favorites	>=	\N	235.0
0a2907e6-de3a-4ab1-b6de-bd1d679a7ffb	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	episodes_class	==	short	\N
1af9a636-a129-492b-bccc-04f8589339c4	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	duration_class	==	long	\N
7d75df3b-2ceb-4046-b4a2-435c7eb99b83	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	type	==	Movie	\N
8d48f222-3573-4244-a819-b11fb30da539	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	score	>=	\N	8.58
8231210a-921a-41d3-8743-dfa314b02747	7285f2b8-ef82-4eff-a662-38a0f6a0915a	anime_dataset	source	==	Manga	\N
9f2701b9-12d0-4230-b078-d07a107960c8	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	user_details	rewatched	>=	\N	0.0
6727efe0-ca93-4991-a1cc-2147f47f3e2f	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	members	>=	\N	137729.0
390b92c4-357e-4b1f-8358-522c668d485f	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	episodes	>=	\N	1.0
d9469c34-b7f7-47c7-b7fd-35d898254729	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	score	>=	\N	8.58
2e3aa2ef-e29f-4d98-b0cb-f27066b71ff3	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	episodes_class	==	short	\N
b236c709-58bd-4874-9ba6-8b021ea2f0c9	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	rank	>=	\N	110.0
d8e33baa-1aed-44f6-8730-17b83d2521d1	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	producers	==	Kodansha	\N
c5c4df7f-79c8-47a9-bb19-4a60ea9a3d27	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	popularity	>=	\N	1817.0
c8314c9e-4571-417c-b6d9-17b4f8906c64	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	studios	==	Artland	\N
2220db05-777c-4748-85f4-b6ef66fdef8b	d1466bd8-1607-47c6-86c8-cd2d6d4d99f9	anime_dataset	status	==	Finished Airing	\N
b2b41ffb-7243-4126-8f7d-2fcd69ea4975	59e71238-88c9-4993-8def-3806d5cbbd2f	user_details	rewatched	>=	\N	0.0
66e9cab0-5a1e-4cdc-a4c2-a57c5808fa83	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	type	==	Movie	\N
56d0d193-3b5a-4fe4-8139-5a6c5113f1fb	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	aired	>=	\N	2015.0
cb7e42a3-92e1-4a71-afd7-f8b3be0ea971	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	producers	==	Kodansha	\N
04128d54-d1ac-4b69-afe4-a51b985b83de	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	episodes_class	==	short	\N
a999063d-7179-4df1-9215-89f33e19ecbc	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	genres	==	Supernatural	\N
471c17db-4c3d-4be5-8c1b-6c931fd21d99	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	status	==	Finished Airing	\N
ca366b04-02be-4d1b-94c7-031a9fe5b14f	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	scored_by	>=	\N	54763.0
aabed69b-287f-40b3-992b-cab20f351096	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	episodes	>=	\N	1.0
0c3ffeba-170a-432c-9cda-e4e560c988b1	59e71238-88c9-4993-8def-3806d5cbbd2f	anime_dataset	favorites	>=	\N	235.0
eb2336de-9b83-4b64-b214-44b2a6a64d50	b3907655-7605-4dcd-9efc-62ac5be5e16d	user_details	rewatched	>=	\N	0.0
7723481c-9517-48bc-b3c2-dcdfb5d16e42	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	members	>=	\N	137729.0
1ee1101d-0220-4e07-8d13-43aff4b1eff8	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	scored_by	>=	\N	54763.0
06da132a-f468-4f3e-9cc5-4d6813195171	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	status	==	Finished Airing	\N
c7895037-0d5d-4e8d-93a5-4de971e6a330	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	favorites	>=	\N	235.0
c01646e5-6ade-42be-9a21-8cd8bd0a5fd4	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	episodes_class	==	short	\N
da642b04-ebbd-4239-9c7b-366ca790f063	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	duration_class	==	long	\N
fa6dc973-3311-458f-bd07-d374ec3eb82d	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	type	==	Movie	\N
50f559c0-1bcb-40a0-a021-5b61d080d0d8	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	score	>=	\N	8.58
5ed3d2df-53a1-47cc-aeb9-db3f953459e5	b3907655-7605-4dcd-9efc-62ac5be5e16d	anime_dataset	source	==	Manga	\N
13b05d14-8b99-41f5-8445-4c0687b35898	8dbf69bc-04f2-424d-85cf-af67599ee0a7	user_details	rewatched	>=	\N	0.0
9f3e1639-9739-41a8-bcb4-ea92b0f5d22c	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	popularity	>=	\N	1817.0
715a15be-a543-462b-9bd4-eb9260ade830	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	scored_by	>=	\N	54763.0
6ea618b3-8828-4d54-83a6-b81c933149e0	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	status	==	Finished Airing	\N
ee6046cd-feb7-446d-b764-d5018a791eac	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	producers	==	Kodansha	\N
8211116f-591c-4d9c-a3f9-837d5203e97c	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	genres	==	Supernatural	\N
4a9d66db-a853-4d5a-8bf2-5acebda262f0	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	episodes_class	==	short	\N
0abc2a75-d2e5-4d73-8912-54af37ddcb1f	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	favorites	>=	\N	235.0
a309d6ac-250e-4c14-bedf-9dcdbac88b0e	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	keywords	==	strange girl	\N
80642cec-2dd9-472a-ac3a-d6cf2483dd25	8dbf69bc-04f2-424d-85cf-af67599ee0a7	anime_dataset	duration_class	==	long	\N
4511cb8a-bc86-4f74-94bc-07904eb7a10c	a82b6472-9ea2-430c-b7c3-45965078227c	user_details	rewatched	>=	\N	0.0
34ca5f6d-b3d1-4c67-bcd5-326963a57656	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	members	>=	\N	137729.0
fe0c6836-a5fa-4482-8d6d-36524b61cc66	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	studios	==	Artland	\N
3b3559d0-c5f0-47f3-814f-e31787648c2d	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	popularity	>=	\N	1817.0
eef66747-b2dc-48f7-9156-d98781a289c0	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	status	==	Finished Airing	\N
767c6bfc-a6ce-4a4b-b159-939deef4da9a	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	genres	==	Supernatural	\N
6dc5b45d-e5fa-400f-9c7b-43496d129938	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	episodes_class	==	short	\N
962b83cc-5d54-4a64-9063-098aab3eb616	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	duration_class	==	long	\N
52652b7d-bec5-4956-b7b9-c1a14c306fdd	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	score	>=	\N	8.58
bb45af32-62d4-4f53-8763-7c20bcc8c433	a82b6472-9ea2-430c-b7c3-45965078227c	anime_dataset	source	==	Manga	\N
feff48eb-5910-4e74-af26-fad51ed33e8c	b4a05236-5978-4b62-984a-cc6fc8929ff9	user_details	watching	>=	\N	8.0
0f8f2e23-dd54-4f4e-8233-2dda5b9c0183	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	popularity	>=	\N	66.0
5022ca63-dc6e-4c24-9fdf-8bbe86693608	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	episodes_class	==	medium	\N
5b8ede40-1550-4ad7-9c2e-f345556f8510	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	keywords	==	secretly	\N
be0b5e2b-ce69-460b-965e-d0387b8af30f	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	duration_class	==	standard	\N
e08d73fb-b9d5-4339-9911-6337d0255a67	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	score	>=	\N	7.75
a636dd7e-9182-414b-8bf5-266c70f81c6a	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	producers	==	BS11	\N
49066535-c1ad-4b0e-8196-9b18ed15e1e8	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	aired	>=	\N	2015.0
50f7a443-e194-4c23-b91f-cf25cb958113	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	scored_by	>=	\N	1041447.0
ee2e59d7-4e8d-4436-bb90-76da25c1510c	b4a05236-5978-4b62-984a-cc6fc8929ff9	anime_dataset	type	==	TV	\N
b3082109-dd27-4e42-ac8a-97eac6766b1c	7fb53324-c0dc-4542-92f8-972fd8aaea8d	user_details	watching	>=	\N	8.0
93bbb659-264b-43cd-aaa5-8180f4f13271	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	type	==	TV	\N
4a2b58f8-c6b4-45b2-b665-6699e0deaaa0	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	popularity	>=	\N	66.0
939dc24a-69ee-4166-b13f-98e66494451a	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	episodes_class	==	medium	\N
53bea1e1-7a46-4e8e-b38c-6098f214641d	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	keywords	==	secretly	\N
a1c99d01-371f-4498-a142-d7e403a20550	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	duration_class	==	standard	\N
2cb1bcdb-fb7a-49a0-91bd-a39d47bf239e	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	score	>=	\N	7.75
7559335f-03c0-4918-87a1-2c31b2d8d664	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	producers	==	BS11	\N
0cc017c5-2779-48b8-abf9-28a5efe90987	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	aired	>=	\N	2015.0
6127a09a-4589-45d3-b5b2-eea0d9b46547	7fb53324-c0dc-4542-92f8-972fd8aaea8d	anime_dataset	rank	>=	\N	1204.0
95f0b033-77a4-4a34-8d58-407d019aab4b	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	user_details	watching	>=	\N	8.0
f6a4067c-9251-45f5-842a-329b83bd2c88	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	source	==	Original	\N
c9149adb-5b7d-4f8d-963a-9b001316d158	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	members	>=	\N	1716551.0
b2208e0c-68e7-4292-ac92-a699c591476f	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	aired	>=	\N	2015.0
07cc7456-b95b-4e1c-b81c-0bf271a8f2cc	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	favorites	>=	\N	24571.0
9e889c6d-1870-4b49-9023-9a26b23c1c63	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	scored_by	>=	\N	1041447.0
e743b44b-fba4-4de5-9da5-21e4f685613d	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	keywords	==	secretly	\N
f365b0c2-ff53-47a6-880a-3d7d321f4a57	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	episodes_class	==	medium	\N
2babe370-0988-47e5-94ae-a106300b818a	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	studios	==	P.A. Works	\N
0ee66612-d9db-4ea2-9aad-e7d8310731e0	2d85cda3-989c-41e8-8d76-ff7a37d0a27d	anime_dataset	type	==	TV	\N
84d37a19-4abb-4a23-a823-a4065610ef19	828e4feb-64c3-4de2-8100-65921b2d8f6a	user_details	watching	>=	\N	8.0
7c291af1-d465-407a-9d63-13a15f293432	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	scored_by	>=	\N	1041447.0
18df74ce-30d7-4129-a529-23eee4f31109	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	aired	>=	\N	2015.0
2a1163a0-18df-4135-8238-af16046305a8	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	score	>=	\N	7.75
f0d12c37-9176-4878-b9a9-14867d3ac2e3	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	members	>=	\N	1716551.0
855a6614-800f-40a6-ad38-e4cd07256db5	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	status	==	Finished Airing	\N
68860d5d-8769-402a-9f60-5d0824f54ac4	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	keywords	==	dishonest acts	\N
698b448a-39c3-46ad-81af-6cd22eae23f7	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	episodes_class	==	medium	\N
2afd3fc5-1b9f-47a0-b785-c45276c8efb2	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	studios	==	P.A. Works	\N
6a805915-c6f8-4a21-afbe-8549b9536145	828e4feb-64c3-4de2-8100-65921b2d8f6a	anime_dataset	genres	==	Drama	\N
367e1905-ed78-4647-9f48-dbe703463ecc	b9e02233-4865-42b4-ad3a-f70a6c218fe5	user_details	watching	>=	\N	8.0
58e5db98-ac65-40bc-bdf3-b1ae9c5a7187	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	type	==	TV	\N
54b2d943-0c5e-45e1-a39d-df91199375d8	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	studios	==	P.A. Works	\N
7f7dac15-8a49-488f-b9b1-ea9bfff3279c	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	episodes_class	==	medium	\N
dcfaf325-f3a5-4ba9-8919-93e330ce975f	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	members	>=	\N	1716551.0
a3a9bedb-3655-4c0e-b8bd-a9845d426059	eb310f6f-dfa3-4194-96b0-d3945a9a660d	user_details	watching	>=	\N	8.0
04851103-ad69-41cc-9dc2-e4beae4440db	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	keywords	==	eventually stopped	\N
a3b03656-31ee-4e95-9b6d-3f7e897d14cb	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	studios	==	P.A. Works	\N
5351ca6e-bebf-4953-8a9a-6adb1ee67447	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	episodes_class	==	medium	\N
84ecce73-e021-4b7c-904b-557f5c7cc39a	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	favorites	>=	\N	24571.0
4901f152-8d34-4302-b83e-5fb390a8c068	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	score	>=	\N	7.75
c63305a0-f243-4010-bd68-5de468e2b899	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	rank	>=	\N	1204.0
28340726-87f3-411b-a6c4-0019d55ef9f1	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	producers	==	BS11	\N
f161e8b2-8284-47b3-80bd-a976e31b886d	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	aired	>=	\N	2015.0
d9e58be2-49bc-4e7f-b1b6-67324dbcdc95	eb310f6f-dfa3-4194-96b0-d3945a9a660d	anime_dataset	scored_by	>=	\N	1041447.0
f7fab24c-3352-4257-ad7a-59a7f5b7052b	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	user_details	watching	>=	\N	8.0
2020288c-6a1c-4d26-bbb1-a35ead99c815	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	type	==	TV	\N
d394a631-c390-4813-ad22-2925c4a57fbd	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	aired	>=	\N	2015.0
a740169a-b6c7-4804-af79-197d50dba140	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	keywords	==	dishonest acts	\N
0fb27322-b792-4af4-8740-aa60726758bb	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	favorites	>=	\N	24571.0
ca7f7a12-f1e1-4150-bdfd-e0e42bc0f5e1	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	members	>=	\N	1716551.0
9e98d6dd-7f1f-4c86-810b-2aa97275a768	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	episodes	>=	\N	13.0
81683261-66e7-4cfb-81ce-609986169614	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	episodes_class	==	medium	\N
f347b358-17c1-43f4-be22-a677aacae681	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	genres	==	Drama	\N
3e351de6-a3d3-4347-9e0c-ab5d89925397	8a6a9cb6-1ea8-4941-aa4a-831e175c0538	anime_dataset	rank	>=	\N	1204.0
13c94bb2-5093-49b1-82f2-caeeae5405d9	fe22dad7-1104-4d3a-bd48-079248abe538	user_details	watching	>=	\N	8.0
aa57f48e-bfd4-4a84-8621-3318b1c3ba5b	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	studios	==	P.A. Works	\N
0c900111-4456-42d7-88dd-d1feda454877	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	aired	>=	\N	2015.0
49969f43-d755-4a94-bbf5-04f2cabd4afa	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	keywords	==	secretly	\N
6d8f2347-59ea-4fd7-bda1-e52374dcb824	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	duration_class	==	standard	\N
09963cec-29dc-435a-9cdd-7be47746239c	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	score	>=	\N	7.75
c0cd1803-ed7e-412b-88fe-aae02fc0af71	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	producers	==	BS11	\N
1a5d9879-70ce-46e4-9cf1-7c2bbb9efbb9	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	premiered	==	summer	\N
e267550e-7a3f-42ec-994b-1169313dc961	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	scored_by	>=	\N	1041447.0
407cee20-c28f-41f1-9b0a-2aedaf889c0a	fe22dad7-1104-4d3a-bd48-079248abe538	anime_dataset	type	==	TV	\N
aa49acdb-3782-423e-a48e-03e40af4cc24	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	user_details	watching	>=	\N	8.0
926b37d0-1d8b-4b5d-bd84-b897d51cfbf5	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	duration_class	==	standard	\N
19b63895-124f-4899-8c47-f285dd924c05	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	aired	>=	\N	2015.0
aac19b3b-00ce-46ee-a775-a587b02173cf	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	favorites	>=	\N	24571.0
ee12c2cf-76f3-49e2-8130-c9a9b2a3ca24	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	scored_by	>=	\N	1041447.0
29068599-ec0d-4612-b318-21302fe0fd24	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	keywords	==	student council serving	\N
ca484a86-826c-4c17-b224-66280c6f3d2a	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	episodes_class	==	medium	\N
c651e519-d65a-4cef-a1e7-f59808966de0	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	genres	==	Drama	\N
21332ddb-0983-4204-92df-1b207b826e59	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	rank	>=	\N	1204.0
e887c82e-3ade-4fd6-b25d-5b02cee9759e	1ab41393-b2d3-4b05-ba9a-4c16c2ab90b9	anime_dataset	type	==	TV	\N
67314ec1-81ad-4a8f-8819-d6b1e715b3f6	abce6278-27a7-471d-b748-bb53bb639e6b	user_details	watching	>=	\N	8.0
90a21c20-ab79-4f12-9c31-24e3c6f7093a	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	type	==	TV	\N
2411b3f9-b08c-4a0f-997f-df016fd35b75	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	popularity	>=	\N	66.0
1bad6902-47fb-41b4-b41a-6fcfa0656b49	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	episodes_class	==	medium	\N
32887419-5e0b-4a7c-93ae-3cbd7e2a8631	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	keywords	==	secretly	\N
c4ab8759-79c8-495d-8baf-fe5db6a3300f	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	duration_class	==	standard	\N
7aae7744-e088-4edf-8708-af935f63d982	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	score	>=	\N	7.75
021d76f2-691f-4386-92fd-7f843faaf289	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	producers	==	BS11	\N
a634c28e-3bad-4b0c-8bc6-60295ec60e36	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	genres	==	Drama	\N
b387ff3f-79cb-4479-ba77-632ac3f1ad7d	abce6278-27a7-471d-b748-bb53bb639e6b	anime_dataset	rank	>=	\N	1204.0
3b09a6b3-5f37-45c2-b2d2-fc49f3688724	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	user_details	watching	>=	\N	8.0
6a728aa1-a7a4-4ab6-8339-e07ddf4136da	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	scored_by	>=	\N	1041447.0
27d01a44-19e1-4461-8707-52d989f208ca	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	producers	==	BS11	\N
05c1baf1-368c-4779-a7fa-1ae287cd7da0	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	score	>=	\N	7.75
4428e62c-c49c-44fd-b4ac-739aa7aa6940	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	type	==	TV	\N
fde0c832-3ada-4209-9742-146f035aea78	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	status	==	Finished Airing	\N
e7c56d70-8977-4c15-96b7-618ff3e30834	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	keywords	==	dishonest acts	\N
63fbcae0-f13d-4efb-86b6-2c09deb3b529	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	episodes_class	==	medium	\N
6e8d7b4f-2129-4762-87e3-a4de7503f9c2	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	genres	==	Drama	\N
9c7cc29f-f102-4960-bf12-7f21758baed0	fe3b28c4-9c30-4666-b8be-e3d32f40b17f	anime_dataset	rank	>=	\N	1204.0
d5518497-e673-4013-8dda-5f2f267a133c	4afb6eff-02eb-4883-b27a-60d9e10de775	user_details	watching	>=	\N	8.0
feff0873-fbe7-4285-b957-8486a872bbf3	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	type	==	TV	\N
53246ca3-4f7f-4a1b-8195-5a034ba335b0	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	popularity	>=	\N	66.0
c31fee3d-e917-4489-9b57-12ee9c8467a6	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	episodes_class	==	medium	\N
f8b715d3-8bf7-4f8d-8761-12200e0c93ba	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	keywords	==	secretly	\N
709c7533-5eb1-4894-a55d-5d53c8fe3869	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	duration_class	==	standard	\N
ac8ee290-afe4-44e7-beab-dbc10756014b	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	score	>=	\N	7.75
79ecc15c-9aef-4565-9259-be284fcc07fc	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	producers	==	BS11	\N
43cbf3d8-cf2f-41cc-ab2f-12039f29d2ba	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	members	>=	\N	1716551.0
3ad38996-94fd-4c07-a67e-6c652cb96c22	4afb6eff-02eb-4883-b27a-60d9e10de775	anime_dataset	studios	==	P.A. Works	\N
c88d9e11-7bc4-457c-b944-0856800eb088	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	user_details	watching	>=	\N	8.0
b5ea494d-e31e-4301-874e-184bace80595	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	studios	==	P.A. Works	\N
87f77a4a-b5ae-4d6b-b496-be365dedd9dd	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	source	==	Original	\N
7c6eae6d-5b74-4dd7-9666-53a702277b9a	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	favorites	>=	\N	24571.0
74a6c9c5-4a7d-4c79-9c06-1d41eb87b419	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	type	==	TV	\N
f39be5db-cd14-46dd-9250-4ec3389e641b	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	duration_class	==	standard	\N
21763eeb-3b1f-46eb-a6fb-c3d618609d8a	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	score	>=	\N	7.75
8dd19e81-7f26-4379-9c61-c8f0e7f09a59	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	producers	==	BS11	\N
12da952d-7a7d-41a2-9c96-823999aeba4f	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	genres	==	Drama	\N
15b7e16a-f301-4f58-88fc-9cfd39b9d37f	9d0f46ac-bfbf-41fd-96d6-b113512f15ea	anime_dataset	rank	>=	\N	1204.0
e70a9fc7-8c1a-4217-bb20-f944030bb4bf	925e8fe4-5e18-4383-9c6b-8e24bb010186	user_details	watching	>=	\N	8.0
a16a8ec7-32af-43cf-9c5b-6a0acc51ae4b	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	source	==	Original	\N
885cc944-afe5-4c08-90cd-487199df321a	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	members	>=	\N	1716551.0
96d14dfa-95c1-4190-ba4b-8e0d8c793eb6	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	aired	>=	\N	2015.0
d5a7486e-cf17-4c6d-b7fa-4fe415aa7789	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	keywords	==	secretly	\N
f85c93b3-b87c-4a90-b9ac-4a049cc994c8	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	duration_class	==	standard	\N
557b814f-f6c1-41f8-91eb-4630d16f0892	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	score	>=	\N	7.75
d88b2f18-cf8d-42a9-b3f8-3c63276ad59a	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	producers	==	BS11	\N
d4ec8538-4af4-4844-91c2-b2ee4bf81749	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	premiered	==	summer	\N
d73271c3-0625-49b6-9837-821da9b28df3	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	scored_by	>=	\N	1041447.0
9fef6beb-8f1d-40fd-a546-ca05424ffc0f	925e8fe4-5e18-4383-9c6b-8e24bb010186	anime_dataset	type	==	TV	\N
9dff7f1f-52c1-4c3b-b039-ff5a5bd4cc69	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	user_details	watching	>=	\N	8.0
02c917ac-d4a8-4bbc-83c3-8fe6c9b7899b	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	favorites	>=	\N	24571.0
d65e176b-29a7-4ae5-bcf4-868dd846f86d	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	premiered	==	summer	\N
9546fad9-4b46-41c0-9a98-d1f256c3be79	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	episodes_class	==	medium	\N
c8d6a19a-a53f-4524-bdce-563e35ba064f	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	keywords	==	secretly	\N
9a08bb97-4115-439f-b2e5-2b66add20a84	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	duration_class	==	standard	\N
777a2b61-6de7-459b-a800-09a9c31ddecb	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	aired	>=	\N	2015.0
95acf4f2-c00c-4af7-8a2f-af83bec4ebb9	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	members	>=	\N	1716551.0
7b9fd381-266d-4da3-8227-df2d55cdc9a7	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	studios	==	P.A. Works	\N
79d11889-d7e8-4f89-9b6b-766fa3290e3e	3e7bf968-36ea-4ad5-8ef8-564cd8276af5	anime_dataset	popularity	>=	\N	66.0
9fcdd063-0b34-48d0-a913-75f90796ed0c	ac14e32d-e9d4-40a7-a246-fb0680cc273c	user_details	watching	>=	\N	8.0
49066730-0648-48d7-b24d-152ea5282b43	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	source	==	Original	\N
3d6e46eb-d570-4fbf-9514-413c770ac0e3	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	members	>=	\N	1716551.0
b3f259a8-0c73-4b9f-96b9-a6d226ce04f7	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	aired	>=	\N	2015.0
5fd1897f-7c3e-4c7a-b23e-9594f070c7b6	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	keywords	==	secretly	\N
5cec4008-4af5-4621-863c-0eeafae6cf6c	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	duration_class	==	standard	\N
65cf47ca-fe4a-4678-8b63-87abe2012d5f	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	score	>=	\N	7.75
d6871c6a-a562-4407-bb34-32f3884b9347	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	producers	==	BS11	\N
d745b1c1-f98f-4ec3-8482-82983ed391d2	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	premiered	==	summer	\N
2ea34ae2-fa6a-4c3e-82eb-87616baf5515	ac14e32d-e9d4-40a7-a246-fb0680cc273c	anime_dataset	genres	==	Drama	\N
d4f0dc89-a380-424f-911d-64081c8d6cd9	3c501a42-adf9-41c5-8fb6-910d5ff50db6	user_details	watching	>=	\N	8.0
b5c527f4-66eb-45ff-a887-ae3d903d741e	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	studios	==	P.A. Works	\N
a8f3391b-d1d7-4781-93db-69df0f17bbc7	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	user_details	watching	>=	\N	8.0
0ae12c78-a483-49dc-b230-40f5fb4e487b	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	rank	>=	\N	1204.0
88c06fed-2ff3-4f9f-b2b6-8c95e8da49fd	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	scored_by	>=	\N	1041447.0
59a0e63a-36bf-4f92-b80e-ac7d805475cc	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	source	==	Original	\N
dace2e07-8d67-4a65-aaf0-838f535137f6	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	premiered	==	summer	\N
9116bf02-fdc1-4522-9f03-2b341840aa03	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	members	>=	\N	1716551.0
8b6aeec4-4661-4952-8737-e4677bd44533	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	studios	==	P.A. Works	\N
cb97ea11-56d9-44dc-aecb-9f9d3aae6be6	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	type	==	TV	\N
f8fa4e48-6b50-4f8a-b504-36e075eb172d	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	popularity	>=	\N	66.0
bd8d2b07-cf39-41b1-8ad6-2d23cd573193	6c80f383-ffbc-4890-a3b1-d98bdbb4c5f3	anime_dataset	duration_class	==	standard	\N
bbd48c21-4e0e-4c03-a297-94e555da7cd3	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	members	>=	\N	1716551.0
a8286c4a-42dc-4993-9c3a-b40fcf19d3c1	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	aired	>=	\N	2015.0
364bff73-4096-43bb-825f-265c14c9eaad	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	duration_class	==	standard	\N
c331e314-6132-4adc-b80c-5c5b0cefd265	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	keywords	==	secretly	\N
52e2d4a7-d7cf-47eb-a991-58b63374c68c	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	episodes_class	==	medium	\N
23e64713-6643-43a4-8116-f1c12da9c76a	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	genres	==	Drama	\N
9ded5ad1-99e6-467a-9d14-f803c469d280	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	scored_by	>=	\N	1041447.0
38b64fca-3f16-40ce-8ab6-46119c4a69dc	3c501a42-adf9-41c5-8fb6-910d5ff50db6	anime_dataset	type	==	TV	\N
92cdf130-d4d1-4519-9f60-bc8112e71ac4	5c100995-3313-4b0f-b374-212adde68ddf	user_details	watching	>=	\N	8.0
2dbabf9a-6def-462c-9b3b-4d9d66006583	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	type	==	TV	\N
de6b7293-9052-45a3-9572-3e49bfc3dfdd	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	studios	==	P.A. Works	\N
f39bb34d-d119-4bcc-9acd-3f2da52ccdb2	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	aired	>=	\N	2015.0
0d560518-cd39-42c2-b90f-266a43dcb4fe	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	favorites	>=	\N	24571.0
63b15ed5-5a1d-4514-b639-45914e03c382	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	duration_class	==	standard	\N
71a0587a-9699-495d-9a3f-8c3e62cddcb2	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	keywords	==	secretly	\N
7a63fbc0-8222-47aa-8920-3bf5631a8201	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	episodes_class	==	medium	\N
3aed0f50-b9e7-4f6a-b04e-9e0e7bcf14b0	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	popularity	>=	\N	66.0
c3fb38a3-6c5f-497c-87f5-49c0e561cbac	5c100995-3313-4b0f-b374-212adde68ddf	anime_dataset	rank	>=	\N	1204.0
e2c8d2b8-a71f-49d9-86ce-cca232dc58ee	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	user_details	watching	>=	\N	8.0
4ef747f6-7ad1-4794-a525-a7fe525dead9	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	scored_by	>=	\N	1041447.0
8489caa7-ae0c-4068-bec4-35ee96b5f3dc	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	members	>=	\N	1716551.0
63fa208f-8849-4cc3-aa6d-9fdc4614de8c	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	score	>=	\N	7.75
21abb2d9-43a7-42c7-93ef-2e13ae6607e5	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	duration_class	==	standard	\N
54dc4c00-9561-477a-819d-bc5cff974609	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	keywords	==	secretly	\N
1485f1ea-63e0-46c1-ad73-be720445f37e	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	episodes_class	==	medium	\N
0097743e-429c-4677-a81d-04ab92a5ac60	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	popularity	>=	\N	66.0
f1be8f3d-8ec4-44d8-9e86-f659641a56a0	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	type	==	TV	\N
8ce6c433-1409-4c05-ac6f-f067b769cf86	8ef6e865-f6c8-4bb4-bb74-5cfccd8558a5	anime_dataset	rank	>=	\N	1204.0
596eaeda-9218-4501-b8b3-766ceaac1a4d	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	user_details	watching	>=	\N	8.0
acfa8aca-1d40-4c35-9dd3-508cc22c8c29	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	keywords	==	mind	\N
765aa14c-8819-4f1e-95bc-c67876d42f5d	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	status	==	Finished Airing	\N
a830fd1a-9609-401d-bec7-71c2b4e698d8	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	studios	==	P.A. Works	\N
7d35d6f2-121e-4492-870c-4d11795758b5	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	episodes_class	==	medium	\N
6b006b1b-d87a-4cd5-9db4-40bad86da42b	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	members	>=	\N	1716551.0
6ce197fb-fea4-4891-bf66-3cbd1e83341f	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	favorites	>=	\N	24571.0
19e47117-b95b-4700-bd51-313fc479a735	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	genres	==	Drama	\N
22462ea6-86e4-4e32-8fbb-59294e664004	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	scored_by	>=	\N	1041447.0
cd95fd3b-d0b3-4b91-aae3-5eaa3b23c8fe	3e8a498c-aadf-4a45-9bcd-a8a6a29a62e3	anime_dataset	rank	>=	\N	1204.0
3307d67c-8a94-4024-8194-cc5f6f3140ff	22848b98-19e4-426c-9991-267149693761	user_details	watching	>=	\N	8.0
9dbaade2-24a2-4213-bbad-4c604516f587	22848b98-19e4-426c-9991-267149693761	anime_dataset	premiered	==	summer	\N
40f343ad-c63a-418c-9096-b70b329fe924	22848b98-19e4-426c-9991-267149693761	anime_dataset	episodes	>=	\N	13.0
3109eb9d-9a42-45ec-af60-7558ddceeee5	22848b98-19e4-426c-9991-267149693761	anime_dataset	source	==	Original	\N
29ccb283-c8b7-4f13-8936-53db308d7f87	22848b98-19e4-426c-9991-267149693761	anime_dataset	favorites	>=	\N	24571.0
5c9ba53f-11b8-415e-ad6f-f45a653c585d	22848b98-19e4-426c-9991-267149693761	anime_dataset	score	>=	\N	7.75
1afef606-3eb9-47c2-b674-d393f979d3e1	22848b98-19e4-426c-9991-267149693761	anime_dataset	episodes_class	==	medium	\N
14a66af9-876b-44ba-940d-6083dc317436	22848b98-19e4-426c-9991-267149693761	anime_dataset	studios	==	P.A. Works	\N
0a2e584f-50c4-43ba-9226-6065a6e0f0ef	22848b98-19e4-426c-9991-267149693761	anime_dataset	rank	>=	\N	1204.0
98d84543-a5c0-4d3f-9d0a-2bc8e2b49d20	22848b98-19e4-426c-9991-267149693761	anime_dataset	aired	>=	\N	2015.0
c583fe6f-f19a-488b-816e-04038943f372	923c8b80-0dfe-46c5-89bb-123a6e47dd93	user_details	watching	>=	\N	8.0
2ca7c72d-1f89-4c8c-961d-ef3fcc2da83f	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	source	==	Original	\N
84151209-17ac-473b-a064-f7370b534042	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	members	>=	\N	1716551.0
aa42a167-df30-448b-a669-57d366a527f0	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	aired	>=	\N	2015.0
e5a2b3ac-ffac-4ff5-8604-e85a0dbc52af	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	favorites	>=	\N	24571.0
176c127a-a7f7-49c5-b96d-17016b9be19d	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	scored_by	>=	\N	1041447.0
4c02238e-a20e-4f0c-9508-77b9972aca8c	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	keywords	==	secretly	\N
741c6c77-f2ef-4f9d-bebf-eeeb01a1795b	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	episodes_class	==	medium	\N
5724ee0c-a385-4f2d-a387-0da46a24c83e	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	genres	==	Drama	\N
99f6915d-ae60-4550-a626-1fc731c4034d	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	rank	>=	\N	1204.0
c68af112-0712-43ac-a56f-b4fea09447c0	923c8b80-0dfe-46c5-89bb-123a6e47dd93	anime_dataset	type	==	TV	\N
70b0ead6-0b36-4514-bb8b-bd2e2d6b2537	b310581d-6be8-46a8-9ae5-11358d098e5c	user_details	watching	>=	\N	8.0
9ee7cdb0-9ec9-40d1-b64b-0b4399ab9aae	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	aired	>=	\N	2015.0
57781d69-d88e-4286-8fdf-4db7d0199e32	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	scored_by	>=	\N	1041447.0
970c98e5-d50c-435c-a652-c2f4d9759cc2	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	studios	==	P.A. Works	\N
53855e80-d907-4aee-82d9-499f26d5b403	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	favorites	>=	\N	24571.0
829b1c8c-7d96-4472-8bf1-efa7148e6518	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	members	>=	\N	1716551.0
99b1529a-e151-459c-b3e6-64909ad2d8ee	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	episodes	>=	\N	13.0
225c2d32-ff63-4ce4-9914-50024e24b125	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	episodes_class	==	medium	\N
35cf3b1b-0716-486e-94e6-3efa3a529855	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	genres	==	Drama	\N
1f50f122-18bd-4c07-8a63-1bede5aa02a7	b310581d-6be8-46a8-9ae5-11358d098e5c	anime_dataset	rank	>=	\N	1204.0
b8817ed2-36b9-4c26-9d79-53966392715c	ae497e26-2f77-45b7-b44a-85dd3863f584	user_details	watching	>=	\N	8.0
5470ef07-8724-4ece-a082-e7954ea959b3	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	studios	==	P.A. Works	\N
5508378b-6837-4682-83f9-51a676a0a4fb	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	members	>=	\N	1716551.0
b65e4712-7717-4cd0-adad-6a868aabcbda	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	aired	>=	\N	2015.0
edfef311-4087-4b85-bb0f-acf6d513f68c	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	favorites	>=	\N	24571.0
87be20c2-d482-4b6d-856d-f33d8b60a0f4	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	duration_class	==	standard	\N
41130c5c-40cb-4336-8765-9d065c9d0fcb	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	keywords	==	secretly	\N
30f6262b-33ec-4a3e-8d19-23e13a9bb26a	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	episodes_class	==	medium	\N
8e33f127-2a9d-4e77-af8f-26a90170df44	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	popularity	>=	\N	66.0
e12c6e29-a38c-44e5-a993-d96fd3f7d847	ae497e26-2f77-45b7-b44a-85dd3863f584	anime_dataset	rank	>=	\N	1204.0
377598a4-b582-4a10-a7d5-47e1bde3f688	208baf0c-968c-4706-be00-f504343e2515	user_details	watching	>=	\N	8.0
8f33bbbd-85fc-49b0-9948-eb5e212c1370	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	rank	>=	\N	1204.0
184cdf4c-4de9-482c-9635-943a5d277247	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	studios	==	P.A. Works	\N
65e9f924-ce6f-4239-95ed-2030d28ee215	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	episodes_class	==	medium	\N
b22330a0-b31a-42f1-9d3b-d9142bc6d2a1	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	keywords	==	secretly	\N
614af52b-5928-4b2d-b218-5c4507ef7bb4	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	duration_class	==	standard	\N
44511aaf-677c-479f-b1df-bc71338dbd60	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	score	>=	\N	7.75
c90f429f-5c72-49a3-9d7a-f2980c870ae4	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	producers	==	BS11	\N
d27cc83f-bc0b-4214-95f0-33562d26baf1	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	premiered	==	summer	\N
38bc176a-d4a1-4873-89ee-e1f81d547a04	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	scored_by	>=	\N	1041447.0
71f8fcd7-6364-43e1-ab44-64976ffc9480	208baf0c-968c-4706-be00-f504343e2515	anime_dataset	type	==	TV	\N
d5009b2a-97ef-4dad-9f9a-677f2fa1feee	4af59c30-f7a0-4493-8d54-510de2d052c1	user_details	watching	>=	\N	8.0
99294385-e213-4b21-8424-12105b38e93a	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	scored_by	>=	\N	1041447.0
b7372644-bcd8-481d-bad4-04792efb96bb	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	studios	==	P.A. Works	\N
a09710b9-4fbc-4f4f-a4e9-8dc733980af0	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	source	==	Original	\N
3b84b2c0-584e-42de-9a0b-7417bd034b91	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	members	>=	\N	1716551.0
7ae9121e-5ef1-41ed-aa47-4a76ebc53fb6	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	score	>=	\N	7.75
ee2cef22-5d32-4f14-b230-892e6bd3c5f6	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	favorites	>=	\N	24571.0
0bbbc18d-f965-4720-8ea7-30deadf7c1d0	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	episodes	>=	\N	13.0
8924e7cd-ab03-48dd-9d0c-c59703d3ca5a	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	duration_class	==	standard	\N
bf7e552d-4c2a-4be7-9c55-ba7dd55d36f7	4af59c30-f7a0-4493-8d54-510de2d052c1	anime_dataset	rank	>=	\N	1204.0
f8d4755c-3898-4d1d-a457-5c95ce1ebdb0	686964a0-61c2-4f1b-98fc-e434a160065d	user_details	watching	>=	\N	8.0
42deb076-11aa-4f24-8121-c18262236486	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	members	>=	\N	1716551.0
3456904b-32d1-4bd2-ba2e-a8149176c2b4	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	duration_class	==	standard	\N
a8c5ee91-52c2-4cdf-ba99-085d1f97dd79	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	episodes_class	==	medium	\N
f0399a5b-0fed-459b-8f62-77cc552edd21	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	keywords	==	dishonest acts	\N
bb0c46fd-add7-4a13-984f-b13f8b50b1c3	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	status	==	Finished Airing	\N
e9b596b4-6936-46a9-85c0-31f56f762076	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	type	==	TV	\N
3ca816ca-ebc2-4738-8874-edfdee44260c	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	aired	>=	\N	2015.0
5717e216-862b-46c2-9faa-b6f690a72949	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	popularity	>=	\N	66.0
ea9c5687-337b-4fb3-ba0c-58c42a35c893	686964a0-61c2-4f1b-98fc-e434a160065d	anime_dataset	rank	>=	\N	1204.0
bae2ada1-45fa-4e7c-9add-dc2a1678bebd	2a2e4973-2e9d-459c-b549-39a63635a70d	user_details	watching	>=	\N	8.0
ae357e95-ab90-4ab0-8c53-87ee94afb8a4	a0af810a-1708-4c51-9e9f-00536fa77eb0	user_details	watching	>=	\N	8.0
4a237be3-3076-47ce-a9ea-357006489f5b	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	rank	>=	\N	1204.0
ee56d605-dbd0-4384-ba4c-995ad7a2409a	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	type	==	TV	\N
90f1ec49-056d-487f-8c68-906553e27d3d	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	source	==	Original	\N
a5f951d4-66f5-4b4f-9786-ad53eee0aa68	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	members	>=	\N	1716551.0
c7c72696-1374-49df-83cb-d9b8fd0f8c1f	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	episodes	>=	\N	13.0
ac8c0b9b-c4fe-4fc0-9829-44aa63ea7ee7	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	aired	>=	\N	2015.0
e8f5f8f4-a2de-45e0-a357-77eef9abc9e8	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	duration_class	==	standard	\N
7c7e3d6b-647c-41af-9508-54ff4526195e	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	scored_by	>=	\N	1041447.0
93d316eb-5948-42b7-8720-6ee946afe440	a0af810a-1708-4c51-9e9f-00536fa77eb0	anime_dataset	score	>=	\N	7.75
88f6dd0b-5750-48ec-80b5-23711d15eae9	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	status	==	Finished Airing	\N
015c5dba-a729-4a7c-98eb-d7972086f413	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	genres	==	Drama	\N
dc2bacc7-b0b2-4419-8113-7778b6203ba7	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	favorites	>=	\N	24571.0
c3c53a69-6b6d-4f6e-84a0-a8293b052fe6	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	members	>=	\N	1716551.0
005a3ca6-a738-4ebc-bf59-c0a8a17ecbdc	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	episodes_class	==	medium	\N
ee5fdb1c-9877-48f7-966d-1e5471c58b5a	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	studios	==	P.A. Works	\N
76fbdd7d-0d70-4cf2-b712-b1b3754dd45a	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	scored_by	>=	\N	1041447.0
8b5a5b0f-e78a-4cc3-a9b1-d57d1957850e	2a2e4973-2e9d-459c-b549-39a63635a70d	anime_dataset	type	==	TV	\N
e6876f09-b670-4f94-b978-b3430468822b	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	score	>=	\N	7.75
a7bfcf98-c3a9-40a5-bf59-b250b57f875d	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	favorites	>=	\N	24571.0
f60fc551-012a-473f-b55d-2a2797fca26b	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	genres	==	Drama	\N
45275456-7202-4dac-8c55-b9ad4209f499	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	aired	>=	\N	2015.0
be8e4e59-a216-43e9-82a4-aa89fcf93960	b9e02233-4865-42b4-ad3a-f70a6c218fe5	anime_dataset	duration_class	==	standard	\N
0934602c-6ad0-421f-b753-3f019bc45f80	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	user_details	watching	>=	\N	8.0
978f36d0-a7fe-4fd7-bf33-02e70b01f9fb	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	studios	==	P.A. Works	\N
142e3040-f09f-4c07-a608-ca9e2f8f0995	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	source	==	Original	\N
f9dd1859-2254-4737-afca-793121cd1d84	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	favorites	>=	\N	24571.0
70d5c54c-aaa9-4be3-acaf-a4183b1035d0	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	score	>=	\N	7.75
da77d542-d3b2-4d70-a6b9-a07f43c201e3	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	keywords	==	secretly	\N
32586e5d-2333-4a57-b8fc-c7a826040a6b	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	episodes_class	==	medium	\N
b3a29bdf-5780-4121-86f2-deb0fafea7c4	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	genres	==	Drama	\N
20e5ac39-4382-4fb0-8681-775ea3e40677	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	rank	>=	\N	1204.0
6b01f967-79a9-4600-869a-68bc4a902d04	8e857d45-a82e-4fc6-ab2e-77e97d0ab743	anime_dataset	type	==	TV	\N
e641f453-e71f-4387-ad68-4e66fe4a6a46	f0ab426b-97a2-4b38-9126-f92fc1380e97	user_details	watching	>=	\N	8.0
b9929cb2-b4c2-4598-8684-71fce44a0332	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	source	==	Original	\N
ad077e1d-412c-4329-8c64-e609bd68ca2c	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	scored_by	>=	\N	1041447.0
ac658532-7675-4a9e-9c2e-46b66232a44d	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	duration_class	==	standard	\N
67a0f713-42ff-41ec-be2d-a63ecd3edecd	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	keywords	==	dishonest acts	\N
2e1f528d-db65-4991-afc1-6b7214969140	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	members	>=	\N	1716551.0
616e267c-02d0-4087-9efa-6eb91f8db480	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	favorites	>=	\N	24571.0
34698c69-d945-4085-8a7b-399648e28008	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	aired	>=	\N	2015.0
effbec91-e698-4549-85ef-cab59cb67a2f	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	type	==	TV	\N
a3f21cd1-17da-4a8c-a85b-dea9fc6d6d8f	f0ab426b-97a2-4b38-9126-f92fc1380e97	anime_dataset	premiered	==	summer	\N
c3226cd8-2dbb-4a06-bf7c-e7a9d7e92bd7	44089aad-3502-4ac5-9a39-a5be29a27ec5	user_details	watching	>=	\N	8.0
91d6ffec-458c-4245-af1c-285b967d7f6b	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	rank	>=	\N	1204.0
79a8aa31-cb94-46a0-8fcb-ae3a13f7bafd	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	genres	==	Drama	\N
6f594397-8817-46e6-903e-c2e3f5534877	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	episodes_class	==	medium	\N
ca5d05d9-32e1-4da4-ad41-9439e78cc8db	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	episodes	>=	\N	13.0
97696aa5-4ee2-4e0a-bebd-1c4a0959cc24	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	members	>=	\N	1716551.0
c21cf775-70e8-4018-bb57-d47310527eb3	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	favorites	>=	\N	24571.0
e4fab265-bd66-49ad-b22c-ccb8e3b4cc3d	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	aired	>=	\N	2015.0
5251c897-1c58-4018-a9e1-73627b5350bb	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	source	==	Original	\N
5982feae-d6fa-4734-a843-728217399fb2	44089aad-3502-4ac5-9a39-a5be29a27ec5	anime_dataset	duration_class	==	standard	\N
515123ca-4006-4097-b777-5e58d913cfa1	442ce7d7-5851-4576-af61-0adf82b67404	user_details	watching	>=	\N	8.0
717143ac-e2fb-4a57-9d69-3019c70e93a2	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	aired	>=	\N	2015.0
e4a11990-ced7-4929-a74a-cdf00ed93a01	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	studios	==	P.A. Works	\N
5108831a-4c72-4724-a54d-6249aac5b41b	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	favorites	>=	\N	24571.0
d8702428-835b-49e7-9a77-2c34e5f88550	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	scored_by	>=	\N	1041447.0
5953ce90-3404-458b-9ee8-88b7c16a9700	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	keywords	==	secretly	\N
aeca1869-8d4f-4068-8826-f3663cb495cd	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	episodes_class	==	medium	\N
52ab17a9-0e86-49d7-860a-94af3e0e8dd2	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	genres	==	Drama	\N
32dfe6dc-3a4b-4345-88ca-37083eff19de	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	rank	>=	\N	1204.0
46ee51f9-b665-4192-93af-c6165f751b08	442ce7d7-5851-4576-af61-0adf82b67404	anime_dataset	type	==	TV	\N
4ffeb606-2d41-455f-b6c9-5ad2fa95e3ed	df871e48-2c98-4916-b770-d089f8eb83d8	user_details	watching	>=	\N	8.0
54a5b895-1d81-4df0-a2cf-1818f49d69e5	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	type	==	TV	\N
da0c2168-8a25-44fb-82f5-63b2b2d36249	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	scored_by	>=	\N	1041447.0
3cfaa5be-aac5-4831-b0f7-8576dbda9e9e	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	premiered	==	summer	\N
22843a71-621d-422b-ae40-ea535b7248b7	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	producers	==	BS11	\N
78196a49-4413-4ea3-92cf-258876dd80e4	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	score	>=	\N	7.75
f890e1a5-6fab-474c-af69-e54043a790b2	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	aired	>=	\N	2015.0
529f260e-7111-4d06-ac92-c95b863a6445	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	members	>=	\N	1716551.0
eb6f331f-ff77-4a28-905e-e2e2c97104cf	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	studios	==	P.A. Works	\N
a8c6a5c5-3a79-42bd-ba74-fa10cb1d2038	df871e48-2c98-4916-b770-d089f8eb83d8	anime_dataset	popularity	>=	\N	66.0
24aa9150-37c3-4b20-9412-cfc5f92abe32	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	user_details	watching	>=	\N	8.0
e7652e8f-421b-428a-acaf-8413802c4c01	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	source	==	Original	\N
16466e4a-e9d5-439d-b79a-d8e1f6222147	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	popularity	>=	\N	66.0
09fe2aed-99ef-41f4-964f-8fe85afda1d1	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	keywords	==	secretly	\N
c3997838-91b7-49a8-ade8-c6d1872e5da2	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	duration_class	==	standard	\N
af50ed72-6dbf-4444-9701-2a6557ab1544	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	score	>=	\N	7.75
8f13c281-b76a-4978-bff4-9050efa2464f	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	episodes_class	==	medium	\N
e2c4c950-b0d8-4e0d-852a-4e5a84053159	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	aired	>=	\N	2015.0
9d3a4575-e487-404a-9c5b-41e9a9839983	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	rank	>=	\N	1204.0
f68374b7-ba20-43f8-84c8-528bda546e26	ce9a9dcd-171f-4bbd-ba35-21c0911aca4f	anime_dataset	scored_by	>=	\N	1041447.0
3ff94afa-d38c-4bf2-9be1-3ea98e3cf3b8	1f8c64e4-2ced-49fc-8b61-42184624d2ed	user_details	watching	>=	\N	8.0
8ab89187-d685-4308-ae35-5c6b3140bf21	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	keywords	==	mind	\N
434af9fd-5040-4f77-9c1b-daf66f1309d3	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	status	==	Finished Airing	\N
0fdfa804-0631-491f-9a76-b6e3166a1558	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	studios	==	P.A. Works	\N
dd98c01a-88c8-41a5-816b-097486c99ed8	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	episodes_class	==	medium	\N
becc6d3e-fe4a-4538-afb6-681b19891f16	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	members	>=	\N	1716551.0
c0d243c4-62ed-4950-9d59-91de6b480b08	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	favorites	>=	\N	24571.0
d3449855-5894-4166-84f8-25c089f79690	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	producers	==	BS11	\N
d994dfb4-63df-4319-a04d-5aaba2258b1f	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	aired	>=	\N	2015.0
9cfe7962-8c68-4407-9807-6a6e0dc85926	1f8c64e4-2ced-49fc-8b61-42184624d2ed	anime_dataset	rank	>=	\N	1204.0
9fa30de8-e1fe-4fef-baf4-ba8b823c689d	c5820446-f6a2-424a-9cc1-9221395c27f9	user_details	watching	>=	\N	8.0
d60f3810-6586-4512-8359-347e23ef5716	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	episodes	>=	\N	13.0
7ca47af1-51f4-4ed4-b1a7-95b8d0e53ad8	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	aired	>=	\N	2015.0
5ee2d8e9-ab1f-4efa-8fec-d93a701f4085	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	episodes_class	==	medium	\N
13510f24-7a85-416f-a610-20d16eac3d24	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	keywords	==	secretly	\N
90be9c21-043d-446a-b03e-d0caa3e5b2e3	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	duration_class	==	standard	\N
b2280bef-8baa-4204-b030-d5b0ec901968	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	score	>=	\N	7.75
c5757a9e-534f-4640-bec0-677eb3cbe2f7	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	producers	==	BS11	\N
4d6330e9-7611-465b-9764-5d78fd5173ad	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	genres	==	Drama	\N
6027f0e5-eedc-45c9-a200-fa4263def7c9	c5820446-f6a2-424a-9cc1-9221395c27f9	anime_dataset	rank	>=	\N	1204.0
cda5c515-76d7-49c1-81ff-ce2a62745a58	997e80d9-0767-4204-bc4e-5247b2bc34b5	user_details	watching	>=	\N	8.0
65c58cec-8ed0-44b4-96e9-eff37bd40c73	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	genres	==	Drama	\N
34950155-b82e-43ca-b4b7-249759c79be9	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	popularity	>=	\N	66.0
aff524b8-d555-4119-a6da-dde768226680	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	episodes_class	==	medium	\N
9a86b600-3ac1-424f-86f7-ab19197da769	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	keywords	==	secretly	\N
be695232-61a6-4a9e-a525-ed45b5c8413f	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	duration_class	==	standard	\N
7bc2a248-06e7-4e99-ab33-4ea5e25d2246	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	type	==	TV	\N
724c29fa-b9e2-4b8c-abcb-cabb64f6940b	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	studios	==	P.A. Works	\N
a55348ee-a392-4f13-915d-0677e1c62fca	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	producers	==	Tokyo MX	\N
5e0ed9e2-5d90-4b72-a5ef-f207dc323f12	997e80d9-0767-4204-bc4e-5247b2bc34b5	anime_dataset	source	==	Original	\N
766c6db8-823b-4b59-a882-573596c42eef	59f652b2-62e2-473a-ada0-fb577819c17c	user_details	watching	>=	\N	8.0
cbff6c9c-8925-4e67-a63f-c31d1bf0718d	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	type	==	TV	\N
10c56f0a-7af5-4a61-a478-b8038c957afb	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	genres	==	Drama	\N
ee242b05-0973-41d8-bb10-db7ce4dccb76	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	episodes_class	==	medium	\N
41b3488e-fe9a-4f6f-a228-fb28405a79ec	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	keywords	==	dishonest acts	\N
13a9ecaf-fb6e-4e0b-a7fb-a04ac8368ee4	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	status	==	Finished Airing	\N
7ec82a6e-5ae7-4109-bc3a-a80e92854f48	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	score	>=	\N	7.75
a0999a74-ed90-4a5f-8a98-4928dc9f1fd8	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	producers	==	BS11	\N
76db9f1c-91ac-42a0-bcb5-f029d11ac3fb	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	scored_by	>=	\N	1041447.0
23efe615-8f94-4c19-8690-0ae72f9cb3ba	59f652b2-62e2-473a-ada0-fb577819c17c	anime_dataset	premiered	==	summer	\N
3cc0c070-2783-43ef-838d-6a6adaf46715	d9690601-00bb-4de3-9542-b7bb0e10d857	user_details	watching	>=	\N	8.0
9763b070-3c48-4fb3-bc05-4787582bbda5	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	members	>=	\N	1716551.0
b3c65468-c5b7-4561-b685-29e7a07ad87e	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	aired	>=	\N	2015.0
9f497824-df2d-44b4-a9e3-7f2a91cac8b7	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	duration_class	==	standard	\N
6fbc9406-56e4-40a1-9529-1867bd0e6c10	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	keywords	==	secretly	\N
24d8aff9-2b40-4b35-9cb9-1368fd9cd881	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	episodes_class	==	medium	\N
655e4f17-2d7b-429a-8a7d-1e42179de7c4	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	genres	==	Drama	\N
66861945-fbed-42ed-9251-7b5d161a2119	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	scored_by	>=	\N	1041447.0
439f3e06-f873-4a76-9e87-3402170464ea	d9690601-00bb-4de3-9542-b7bb0e10d857	anime_dataset	rank	>=	\N	1204.0
\.


--
-- Data for Name: user_details; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_details (mal_id, username, gender, age_group, days_watched, mean_score, watching, completed, on_hold, dropped, plan_to_watch, total_entries, rewatched, episodes_watched) FROM stdin;
4067	sabbielle	\N	\N	6.80	9.33	1	2	0	0	0	3	0	407
4068	dondave_babyface	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4069	hachibaka	Female	adult	79.40	7.72	11	202	0	10	23	246	6	4682
4070	missing592	\N	\N	111.90	8.36	27	130	8	0	31	196	25	7263
4071	EndlessAnime	\N	\N	43.50	7.48	10	69	0	1	0	80	0	2602
4072	tomee	Male	\N	14.70	7.33	1	43	0	4	0	48	0	842
4073	zeidrich	\N	\N	33.70	8.30	20	95	9	4	5	133	0	1915
4074	saifudin90	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4075	Sayumi	Female	\N	80.90	7.16	18	196	9	23	32	278	4	4755
4076	DarkFlash	Male	\N	152.20	7.28	16	397	29	58	105	605	1	9086
4077	hejdar	Male	adult	38.00	6.72	4	107	4	25	4	144	0	2280
4078	laychie	\N	\N	0.60	9.00	0	3	0	0	0	3	0	28
4079	Muzzy	\N	\N	0.00	0.00	0	1	0	0	0	1	0	1
4080	kYuBi_FoX	\N	\N	419.30	7.53	155	1516	306	4	88	2069	0	26020
4081	dakeru	\N	adult	55.90	8.28	11	86	34	8	22	161	0	3330
4082	xaynie	Female	senior	40.40	7.05	5	101	9	20	19	154	22	2288
4083	porthunt	Male	adult	149.10	6.69	8	479	21	299	105	912	0	8951
4084	oseam	\N	\N	5.10	10.00	1	0	0	0	0	1	0	307
4085	TheIdesofJanuary	\N	\N	1.50	8.33	1	5	0	0	0	6	0	83
4086	EpyonAC	\N	\N	61.00	8.14	8	43	0	0	6	57	80	3526
4087	buttercuppup	Female	adult	1.50	8.00	0	3	0	0	0	3	0	90
4088	betyar	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4089	XxBLxX	Male	adult	105.90	7.28	9	145	4	3	4	165	6	6404
4090	Nanaky	\N	adult	15.70	7.85	1	88	5	1	8	103	0	919
4091	Vale-chan	Female	\N	287.80	7.19	13	493	23	27	50	606	177	17157
4092	Iras	\N	\N	17.60	0.00	10	25	1	0	1	37	0	1050
4093	Darkzeross	\N	\N	101.90	7.85	8	280	2	2	45	337	0	5944
4094	Avitar_Diggs	Male	\N	83.60	6.75	14	259	52	32	0	357	2	4833
4095	deneme	\N	\N	8.50	8.60	3	1	1	0	0	5	0	514
4096	AJ75	\N	\N	52.60	7.58	2	261	24	40	19	346	7	2971
4097	RebelFighter2017	Male	adult	66.50	8.58	6	9	0	0	3	18	18	4155
4098	acira	\N	\N	10.90	0.00	1	16	0	0	0	17	0	660
4099	BrunelloJP	\N	\N	9.50	7.44	3	5	0	1	0	9	17	587
4100	Leode	\N	\N	19.70	8.65	8	28	2	0	3	41	16	2161
4101	wilson_x1999	Male	\N	66.00	7.15	56	185	4	73	68	386	0	4144
4102	Torchic	Female	senior	80.00	8.34	2	118	6	5	1	132	44	4702
4103	luk2	\N	\N	88.70	8.26	18	153	1	11	2	185	55	5403
4104	SweWolf	\N	\N	19.30	7.20	0	42	2	0	13	57	0	1154
4105	Triforceflames	Female	\N	24.40	7.62	3	29	3	4	9	48	0	1459
4106	RyRyMini	Male	adult	78.40	7.03	11	55	1	4	8	79	77	4622
4107	reluctantshadow	\N	\N	246.70	6.83	24	964	6	4	267	1265	0	15693
4108	pearye	\N	\N	41.20	10.00	15	68	5	5	0	93	0	2451
4109	Danke	\N	\N	27.30	0.00	1	81	4	0	0	86	0	1579
4110	Stan07	\N	\N	73.10	7.43	13	183	8	36	5	245	38	4179
4111	alchemyangel11	Female	adult	33.00	9.16	17	40	1	0	0	58	79	1723
4112	Linzywasd	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4113	farid5407	Male	adult	0.60	8.00	1	0	0	0	0	1	0	37
4114	WakeShinigami	Male	senior	5.80	8.67	2	7	0	0	0	9	2	344
4115	Lockjaw7	\N	\N	5.90	5.80	1	9	0	0	0	10	0	384
4116	heardtheowl	\N	\N	24.80	8.35	16	103	87	44	7	257	0	1403
4117	cardslash02	Female	adult	137.40	7.19	11	565	7	18	4	605	0	8081
4118	EnzeroX	\N	\N	0.10	8.00	1	0	0	0	0	1	0	4
4119	cloudyyy	\N	\N	16.70	7.61	10	41	5	11	0	67	0	1060
4120	aznl2onin	\N	\N	2.30	8.83	1	6	0	0	0	7	0	136
4121	janelleski	Female	adult	22.70	7.92	7	27	3	6	5	48	5	1367
4122	DihDiogo	Male	adult	34.70	8.41	42	90	136	7	26	301	5	2141
4123	x-1o7-x	Male	adult	20.70	8.22	6	60	10	1	1	78	0	1222
4124	Yunie	\N	\N	75.30	8.59	34	150	5	1	44	234	0	4539
4125	samnot	\N	\N	30.50	7.79	9	77	7	8	29	130	3	1790
4126	TheGrim	Male	\N	0.00	0.00	0	0	0	0	0	0	0	0
4127	alla	\N	\N	0.00	0.00	0	0	0	0	1	1	0	0
4128	Milaryn	\N	\N	153.50	6.80	41	377	119	82	882	1501	100	9009
4129	windowsmediaplay	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4130	Macro	Male	\N	28.30	8.08	4	36	16	10	2	68	0	1676
4131	bernard090	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4132	leighya	Female	adult	15.60	8.40	2	49	0	1	2	54	0	893
4133	Kobra	Male	adult	104.00	8.19	81	164	15	13	367	640	0	6338
4134	delxd	Male	adult	151.80	8.52	141	323	22	8	187	681	6	9213
4135	desa_chyn09	Female	adult	14.60	8.18	1	19	5	0	4	29	2	880
4136	x-1o8-x	\N	\N	148.10	7.86	6	570	3	9	10	598	28	8842
4137	DarkDays	Male	\N	181.90	7.68	5	647	117	106	397	1272	255	11030
4138	Tenjouname	Male	adult	348.00	7.88	0	1435	23	153	5	1616	0	21860
4139	yurko	Male	\N	0.50	10.00	0	1	0	0	0	1	0	26
4140	graywolf	Male	adult	66.60	6.59	4	273	17	9	39	342	8	3773
4141	un3xpectedfate	Female	\N	69.90	8.59	1	146	111	19	384	661	26	4454
4142	FallenKnight	\N	\N	28.80	0.00	4	65	0	0	10	79	0	1687
4143	Misa_Amane	Female	\N	25.20	10.00	38	59	8	4	88	197	0	1523
4144	fealdad	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4145	Jatan	\N	\N	7.60	8.57	0	7	0	0	0	7	7	465
4146	rgdraconian	Male	\N	18.00	0.00	6	27	0	0	0	33	0	1052
4147	Isamushade	\N	\N	33.20	7.83	4	31	0	0	33	68	11	2013
4148	Onei_Chan	Female	adult	17.10	7.91	1	22	0	0	0	23	27	1010
4149	rutix	Male	adult	203.10	7.86	17	540	22	18	23	620	12	11983
4150	Liunee	Female	adult	74.60	7.36	8	301	13	25	65	412	0	4390
4151	mwgamera	Male	adult	16.70	6.72	0	65	7	3	0	75	1	977
4152	rakka	Male	\N	19.40	7.58	0	57	6	14	31	108	5	1145
4153	shoval-yarkoni	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4154	kokokara	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4155	misschristi	\N	\N	13.20	7.05	1	61	5	9	69	145	12	872
4156	Kuryuu	Male	adult	31.10	6.67	4	47	2	3	23	79	0	1872
4157	Via	Female	adult	80.90	7.75	1	106	16	19	6	148	86	5449
4158	synbiote	Male	adult	43.50	7.86	4	124	11	17	60	216	0	2547
4159	Apogee	Male	\N	32.90	7.01	3	75	7	14	4	103	3	1950
4161	Thage	\N	\N	122.30	8.21	114	512	58	89	64	837	0	7568
4162	Jojibayr	Female	adult	55.00	9.13	1	7	0	0	0	8	45	3981
4163	Hitman66	Male	adult	69.50	7.96	15	107	36	10	26	194	51	5023
4164	hypafro	\N	\N	17.30	9.50	1	1	0	0	0	2	3	1045
4165	AchenDude	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4166	Bar-	Female	adult	155.60	8.73	353	494	13	28	33	921	5	9288
4167	Fisher	Male	\N	96.60	7.07	54	320	44	30	44	492	28	5973
4168	Rhade	Male	\N	3.00	8.67	2	8	0	2	4	16	0	180
4169	KnitaRed	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4170	i6_	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4171	lim9944	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4172	Unok	\N	\N	22.30	8.81	12	33	0	0	0	45	0	1320
4173	hotlinehelp	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4174	totalgirlish	Female	adult	0.00	10.00	2	0	0	0	0	2	0	0
4175	Darkness	Male	adult	85.50	7.14	4	234	17	38	1	294	3	5112
4176	stella_gaia	\N	\N	30.40	6.55	9	6	2	3	0	20	9	1823
4177	matada	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4178	dbzcri	Male	adult	168.30	9.30	45	430	40	31	111	657	24	9773
4179	matannnn4	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4180	zer0tea	Male	adult	31.90	6.96	4	28	2	12	7	53	0	1911
4181	Tablis	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4182	sungus420	\N	\N	15.50	8.06	26	6	2	0	0	34	0	934
4183	mermaidprincess	Female	adult	7.00	8.36	0	8	9	1	9	27	25	1055
4184	NightK	Male	adult	17.10	0.00	3	34	1	0	3	41	0	997
4185	Kyoko-1	Female	\N	36.50	7.21	12	63	6	21	9	111	4	2163
4186	Foxagram	Female	adult	58.70	6.67	2	171	27	5	14	219	2	3525
4187	Feredzhanov	Male	adult	53.30	8.54	3	175	0	7	165	350	28	3117
4188	Coiru	\N	\N	8.60	6.63	3	13	2	10	4	32	0	509
4189	SilentDream	Male	adult	6.20	8.00	1	0	0	0	0	1	0	371
4190	Jin-san	Male	\N	0.00	0.00	0	0	0	0	0	0	0	0
4191	FelysyaEK	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4192	aeonsky	\N	\N	6.30	8.00	1	0	0	0	0	1	2	857
4193	carmelo	\N	\N	27.00	0.00	17	59	7	2	55	140	0	1630
4194	METO	Male	adult	2.50	7.62	3	4	2	3	2	14	0	148
4195	kittenz73	\N	\N	89.10	7.18	13	250	3	11	20	297	2	5277
4196	xforlornhopex	\N	\N	2.30	9.50	0	2	0	0	0	2	0	138
4197	tema-chan	\N	\N	5.10	8.50	3	5	0	0	0	8	4	1283
4198	daisukexriku	\N	\N	0.20	10.00	0	1	0	0	0	1	0	14
4199	Unknown	Male	adult	111.60	7.83	8	199	11	2	17	237	3	6636
4200	joannie	\N	\N	4.70	8.30	5	2	3	0	0	10	0	287
4201	humba	Male	\N	193.30	7.78	12	349	3	47	21	432	15	11695
4202	KenyaSong	\N	\N	1.10	0.00	0	4	0	0	0	4	0	66
4203	MoonCat	Female	adult	43.50	8.30	2	111	21	4	23	161	0	2532
4204	ttmu	\N	\N	46.10	7.52	22	85	0	0	0	107	1	3042
4205	Jinaflagg	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4206	Tyderion	Male	\N	46.80	7.56	9	55	20	10	70	164	5	2753
4207	RIPSKIJ	Male	senior	64.10	7.89	201	271	49	3	63	587	0	3723
4208	garu_daisuki	Female	adult	56.30	7.50	10	147	23	12	45	237	0	3314
4209	crwadsworth	Female	adult	33.60	8.12	5	38	2	0	0	45	0	2014
4210	yasahisa	\N	\N	0.20	0.00	1	0	0	0	0	1	0	12
4211	coldass	Male	adult	1.90	8.50	0	2	0	0	0	2	2	112
4212	bluu82	Male	senior	0.00	0.00	0	0	0	0	0	0	0	0
4213	G0473h	\N	\N	148.30	7.67	15	301	29	30	59	434	70	8782
4214	knivez86	Male	adult	65.10	7.85	8	139	5	0	8	160	4	3801
4215	paranjay	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4216	ralfelor	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4217	devilznemesis	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4218	Devil	Male	\N	163.70	6.01	1	500	5	4	48	558	2	9759
4219	k1ndn3555	\N	\N	168.10	6.55	6	613	33	255	11	918	0	9934
4220	wenz	\N	\N	59.30	7.56	16	241	1	25	81	364	0	3738
4221	DareDevin	Male	adult	102.80	7.88	16	215	7	0	58	296	0	6184
4222	Blaem	Male	\N	24.00	6.64	2	83	2	24	103	214	3	1343
4223	HeadMarine	Male	adult	2.60	10.00	2	2	0	0	0	4	0	151
4224	Bloodygoku	\N	\N	28.60	8.17	11	53	3	0	8	75	5	1643
4225	Palorin	\N	\N	5.20	10.00	1	0	0	0	0	1	0	309
4226	oykc	Male	\N	6.00	0.00	0	27	0	0	0	27	0	369
4227	kErov4	Male	\N	21.10	9.67	19	48	0	0	35	102	0	1245
4228	titi210	\N	\N	0.50	10.00	1	0	0	0	0	1	2	61
4229	xxkillerbunnyxx	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4230	W-General	Male	adult	37.20	8.43	21	103	0	9	78	211	29	2119
4231	elsiey	\N	\N	18.20	2.71	2	67	18	30	40	157	0	1025
4232	PucMan	Male	adult	142.50	6.64	17	479	7	9	0	512	0	8450
4233	fung	\N	\N	2.30	10.00	1	1	0	0	0	2	0	133
4234	xiga	\N	\N	40.70	8.33	2	140	16	23	67	248	0	2344
4235	bamboo	Female	\N	13.30	6.27	8	34	4	24	3	73	16	698
4236	Mamori	\N	\N	8.70	0.00	3	35	0	6	3	47	0	551
4237	MistaMuShu	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4238	eloque	\N	\N	16.40	7.83	3	39	6	1	4	53	0	1013
4239	SGOG	\N	\N	4.10	8.57	5	2	0	0	0	7	1	241
4240	Pairo	\N	\N	49.60	10.00	5	108	3	1	2	119	13	9199
4241	mimiru_kun	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4242	Eamon	Male	\N	110.70	7.54	4	210	1	11	34	260	52	7210
4243	Moi	\N	\N	47.80	7.64	11	177	13	74	16	291	0	2777
4244	RaliAnn	Female	adult	1.40	9.00	1	2	0	0	0	3	0	86
4245	blacky	\N	\N	0.70	10.00	2	0	0	0	0	2	0	41
4246	Sparhawk	\N	\N	0.70	10.00	1	2	0	0	0	3	0	42
4247	heffa	\N	\N	6.70	10.00	2	1	0	0	0	3	0	400
4248	Brewmaster	\N	\N	0.00	10.00	0	1	0	0	0	1	0	2
4249	Big-Brother	Male	adult	44.60	7.92	14	119	3	0	11	147	0	2590
4250	Braaten	\N	\N	7.80	9.33	2	1	0	0	0	3	0	463
4251	evileyevileye	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4252	eviley12evileye	\N	\N	6.80	8.73	7	4	0	0	0	11	9	419
4253	Mikuro	Male	\N	45.50	7.62	0	126	0	2	0	128	0	2697
4254	LordAwesome	Male	adult	14.70	8.86	9	21	6	0	4	40	7	853
4255	ShiftingSilence	\N	\N	12.80	7.46	4	10	0	0	0	14	8	770
4256	Shadow-Chan	Female	\N	53.40	8.78	14	293	11	0	63	381	0	3617
4257	tomspiro	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4258	bakarassus	\N	\N	0.00	0.00	0	0	0	0	0	0	0	0
4259	Slade	Male	adult	30.10	7.88	8	124	14	14	37	197	19	1742
4260	Havokdan	Male	adult	700.90	5.87	126	3814	0	469	18	4427	111	42337
4261	sammo	\N	\N	137.70	7.25	14	385	3	18	1	421	0	8148
4262	Nuderval	\N	\N	21.20	0.00	12	69	0	0	0	81	0	1211
4263	TioErnesto	Male	\N	9.20	8.28	20	30	8	7	0	65	0	534
4264	phazonmasher	Male	adult	83.40	9.09	10	290	18	8	1	327	29	4862
4265	Dreadfish	\N	\N	0.30	6.33	0	3	0	0	0	3	0	8
4266	Kaolla	Male	adult	58.40	7.82	3	92	2	11	4	112	65	3475
\.


--
-- Data for Name: user_score; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.user_score (user_id, anime_id, rating) FROM stdin;
4137	28957	high
4150	28999	high
4150	28979	high
4195	28999	high
4199	28999	high
4201	29067	high
4234	28957	high
4242	28977	high
4253	28957	high
4256	28981	high
\.


--
-- PostgreSQL database dump complete
--

