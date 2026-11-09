#!/usr/bin/env bash
# ren.sh — fecha al inicio + limpieza de nombres. Dry-run por defecto.
# Uso: DRY_RUN=1 ./ren.sh [directorio]
#      DRY_RUN=0 ./ren.sh [directorio]

DIR="${1:-.}"
cd "$DIR" || { echo "No puedo entrar a $DIR"; exit 1; }

DRY_RUN="${DRY_RUN:-0}"
shopt -s nullglob

declare -A MES=(
  [january]=01 [february]=02 [march]=03 [april]=04 [may]=05 [june]=06
  [july]=07 [august]=08 [september]=09 [october]=10 [november]=11 [december]=12
)

# Archivos/patrones a NO tocar nunca
SKIP=("ren.sh" "lista.txt" "*.sh" "*.txt")

procesados=0
omitidos=0
for f in *; do
    [[ -f "$f" ]] || continue

    # ¿Está en la lista de exclusión?
    saltar=0
    for pat in "${SKIP[@]}"; do
        [[ "$f" == $pat ]] && { saltar=1; break; }
    done
    (( saltar )) && { ((omitidos++)); continue; }

    # Verificar que ES una imagen mirando el CONTENIDO, no la extensión
    mime=$(file --brief --mime-type -- "$f" 2>/dev/null)
    [[ "$mime" == image/* ]] || { echo "SKIP (no imagen: ${mime:-?}): $f"; ((omitidos++)); continue; }

    # --- 1) Extraer fecha del inicio si existe
    fecha=""; resto="$f"
    if [[ "$f" =~ ^([A-Za-z]+)\ ([0-9]{1,2}),\ ([0-9]{4})\ at\ ([0-9]{4})([APap][Mm])\ -\ (.*)$ ]]; then
        mes_txt=$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')
        mm="${MES[$mes_txt]}"
        if [[ -n "$mm" ]]; then
            dia=$(printf '%02d' "$((10#${BASH_REMATCH[2]}))")
            anio="${BASH_REMATCH[3]}"
            hora12="${BASH_REMATCH[4]}"
            ampm=$(printf '%s' "${BASH_REMATCH[5]}" | tr '[:lower:]' '[:upper:]')
            resto="${BASH_REMATCH[6]}"

            hh=$((10#${hora12:0:2})); mi="${hora12:2:2}"
            if [[ "$ampm" == "AM" ]]; then
                (( hh == 12 )) && hh=0
            else
                (( hh < 12 )) && (( hh += 12 ))
            fi
            printf -v hh "%02d" "$hh"
            fecha="${anio}-${mm}-${dia}_${hh}${mi}"
        fi
    fi

    # --- 2) Saneamiento (acentos → ASCII, todo lo no [A-Za-z0-9._-] → _)
    limpio=$(printf '%s' "$resto" | iconv -f UTF-8 -t ASCII//TRANSLIT 2>/dev/null)
    limpio=$(printf '%s' "$limpio" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/_+/_/g; s/^_+//; s/_+$//')
    [[ -z "$limpio" ]] && limpio="foto"

    # --- 3) Nombre final
    if [[ -n "$fecha" ]]; then nuevo="${fecha}_${limpio}"; else nuevo="$limpio"; fi
    destino="${nuevo}.jpg"

    # --- 4) Colisiones
    if [[ -e "$destino" && "$destino" != "$f" ]]; then
        i=1
        while [[ -e "${nuevo}_${i}.jpg" ]]; do ((i++)); done
        destino="${nuevo}_${i}.jpg"
    fi

    [[ "$f" == "$destino" ]] && continue
    ((procesados++))

    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry] $f"
        echo "   -> $destino"
    else
        mv -n -- "$f" "$destino" && echo "OK  $f -> $destino"
    fi
done

echo "----"
echo "A renombrar: $procesados   omitidos: $omitidos   (DRY_RUN=$DRY_RUN)"
