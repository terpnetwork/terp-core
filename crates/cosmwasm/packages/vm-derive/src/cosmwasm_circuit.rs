use proc_macro2::TokenStream as TokenStream2;
use quote::quote;
use syn::spanned::Spanned;
use syn::{parse2, DeriveInput, Error};

use crate::code_generators::CodeGenerator;
use crate::parsers::CircuitAttributes;
use crate::validators::{validate_attributes, validate_circuit_struct};

/// Main macro implementation for #[cosmwasm_circuit]
pub fn cosmwasm_circuit_impl(
    attr: TokenStream2,
    item: TokenStream2,
) -> Result<TokenStream2, TokenStream2> {
    // Parse attributes from the macro
    let attrs: CircuitAttributes = parse2(attr.clone()).map_err(|e| {
        Error::new_spanned(
            &item,
            format!("Failed to parse cosmwasm_circuit attributes: {}", e),
        )
        .to_compile_error()
    })?;

    // Parse the struct definition
    let input: DeriveInput = parse2(item.clone()).map_err(|e| e.to_compile_error())?;

    // Validate attributes
    let mut validation = validate_attributes(&attrs, input.span());
    validation
        .errors
        .extend(validate_circuit_struct(&input).errors);

    if !validation.is_valid {
        return Err(validation.to_compile_error());
    }

    // Extract circuit name
    let circuit_name = match &input {
        DeriveInput {
            ident,
            data: syn::Data::Struct(_),
            ..
        } => ident.clone(),
        _ => {
            return Err(Error::new_spanned(
                &input,
                "#[cosmwasm_circuit] can only be applied to structs",
            )
            .to_compile_error());
        }
    };

    // Generate code
    let generator = CodeGenerator::new(circuit_name, attrs);
    let generated = generator.generate();

    // Return the original item plus generated code
    Ok(quote! {
        #item
        #generated
    })
}
